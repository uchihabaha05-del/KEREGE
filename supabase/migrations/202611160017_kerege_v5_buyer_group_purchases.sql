-- KEREGE 5.0: buyer-created public group purchases and supplier offer workflow.
alter table public.group_buys alter column supplier_id drop not null;
alter table public.group_buys
  add column if not exists creator_id uuid references public.profiles(id) on delete cascade,
  add column if not exists product_id uuid references public.products(id) on delete restrict,
  add column if not exists target_people integer not null default 2 check(target_people >= 2),
  add column if not exists counter_price numeric(14,2),
  add column if not exists counter_target_qty numeric(14,3),
  add column if not exists offer_note text not null default '',
  add column if not exists offer_sent_at timestamptz,
  add column if not exists responded_at timestamptz;
alter table public.group_buys alter column price type numeric(14,2);
alter table public.group_buys alter column target_qty type numeric(14,3);
alter table public.group_buys alter column committed_qty type numeric(14,3);
alter table public.group_buys drop constraint if exists group_buys_status_check;
alter table public.group_buys add constraint group_buys_status_check
 check(status in ('open','target_reached','offered','countered','accepted','declined','closed','cancelled'));
update public.group_buys set creator_id=supplier_id where creator_id is null;
alter table public.group_buys alter column creator_id set not null;

create index if not exists group_buys_creator_idx on public.group_buys(creator_id,created_at desc);
create index if not exists group_buys_product_idx on public.group_buys(product_id);

-- Group members' names are visible only to authenticated users who belong to that group,
-- its creator, or its selected supplier.
drop policy if exists profiles_group_members_read on public.profiles;
create policy profiles_group_members_read on public.profiles for select to authenticated
using (
 id=auth.uid() or exists(
  select 1 from public.group_buy_members m
  join public.group_buys g on g.id=m.group_buy_id
  where m.user_id=profiles.id
    and (g.creator_id=auth.uid() or g.supplier_id=auth.uid()
      or exists(select 1 from public.group_buy_members mine where mine.group_buy_id=g.id and mine.user_id=auth.uid()))
 )
);

drop policy if exists groups_public_read on public.group_buys;
create policy groups_public_read on public.group_buys for select to authenticated
using(status in ('open','target_reached','offered','countered','accepted') or creator_id=auth.uid() or supplier_id=auth.uid());
drop policy if exists buyer_group_insert on public.group_buys;
create policy buyer_group_insert on public.group_buys for insert to authenticated
with check(creator_id=auth.uid() and supplier_id is not null and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='buyer'));
drop policy if exists supplier_group_insert on public.group_buys;
drop policy if exists supplier_group_update on public.group_buys;
create policy group_creator_update on public.group_buys for update to authenticated
using(creator_id=auth.uid() and status in ('open','target_reached','countered'))
with check(creator_id=auth.uid());
drop policy if exists supplier_group_delete on public.group_buys;
drop policy if exists group_members_read_own_or_supplier on public.group_buy_members;
create policy group_members_read_all_visible on public.group_buy_members for select to authenticated
using(exists(select 1 from public.group_buys g where g.id=group_buy_id and
 (g.status in ('open','target_reached','offered','countered','accepted') or g.creator_id=auth.uid() or g.supplier_id=auth.uid())));
grant select on public.profiles to authenticated;
grant select on public.group_buys,public.group_buy_members to authenticated;
revoke insert,update,delete on public.group_buys,public.group_buy_members from anon,authenticated;

create or replace function public.create_buyer_group_buy(
 p_product_id uuid,p_price numeric,p_target_qty numeric,p_target_people integer,p_ends_at timestamptz
) returns uuid language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid:=auth.uid(); v_product public.products%rowtype; v_group uuid;
begin
 if v_user is null or not exists(select 1 from public.profiles where id=v_user and role='buyer') then raise exception 'Создавать группы могут только покупатели'; end if;
 if p_price is null or p_price<=0 or p_target_qty is null or p_target_qty<=0 or p_target_people is null or p_target_people<2 then raise exception 'Проверьте цену, объём и количество участников'; end if;
 if p_ends_at is null or p_ends_at<=now() then raise exception 'Укажите будущий срок набора'; end if;
 select * into v_product from public.products where id=p_product_id and is_active=true for share;
 if not found then raise exception 'Товар не найден или недоступен'; end if;
 if p_price>=v_product.price then raise exception 'Целевая цена должна быть ниже обычной цены'; end if;
 insert into public.group_buys(creator_id,supplier_id,product_id,title,unit,price,target_qty,target_people,city,ends_at)
 values(v_user,v_product.supplier_id,v_product.id,v_product.name,v_product.unit,p_price,p_target_qty,p_target_people,v_product.city,p_ends_at)
 returning id into v_group;
 return v_group;
end $$;

create or replace function public.join_group_buy(p_group_buy_id uuid,p_quantity numeric)
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid:=auth.uid(); v_group public.group_buys%rowtype; v_member uuid; v_old numeric:=0; v_total numeric;
begin
 if v_user is null then raise exception 'Требуется авторизация'; end if;
 if p_quantity is null or p_quantity<=0 then raise exception 'Количество должно быть больше нуля'; end if;
 if not exists(select 1 from public.profiles where id=v_user and role='buyer') then raise exception 'Участвовать могут только покупатели'; end if;
 select * into v_group from public.group_buys where id=p_group_buy_id for update;
 if not found or v_group.status not in ('open','target_reached') or v_group.ends_at<=now() then raise exception 'Набор в группу закрыт'; end if;
 select id,quantity into v_member,v_old from public.group_buy_members where group_buy_id=p_group_buy_id and user_id=v_user and status<>'withdrawn' for update;
 v_total:=v_group.committed_qty-coalesce(v_old,0)+p_quantity;
 if v_total>v_group.target_qty then raise exception 'Количество превысит целевой объём группы'; end if;
 if v_member is null then insert into public.group_buy_members(group_buy_id,user_id,quantity) values(p_group_buy_id,v_user,p_quantity) returning id into v_member;
 else update public.group_buy_members set quantity=p_quantity,status='interested' where id=v_member; end if;
 update public.group_buys set committed_qty=v_total,
 status=case when v_total>=target_qty and (select count(*) from public.group_buy_members where group_buy_id=p_group_buy_id and status<>'withdrawn')>=target_people then 'target_reached' else 'open' end
 where id=p_group_buy_id;
 return v_member;
end $$;

create or replace function public.submit_group_buy_offer(p_group_buy_id uuid)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_group public.group_buys%rowtype; v_people integer;
begin
 select * into v_group from public.group_buys where id=p_group_buy_id for update;
 if not found or v_group.creator_id<>auth.uid() then raise exception 'Отправить предложение может только создатель группы'; end if;
 if v_group.status not in ('open','target_reached','countered') then raise exception 'Предложение уже отправлено или группа закрыта'; end if;
 select count(*) into v_people from public.group_buy_members where group_buy_id=p_group_buy_id and status<>'withdrawn';
 if v_people<v_group.target_people then raise exception 'Пока недостаточно участников'; end if;
 if v_group.committed_qty<v_group.target_qty then raise exception 'Пока не набран необходимый объём'; end if;
 update public.group_buys set status='offered',offer_sent_at=now(),responded_at=null where id=p_group_buy_id;
end $$;

create or replace function public.respond_group_buy_offer(p_group_buy_id uuid,p_decision text,p_counter_price numeric default null,p_counter_qty numeric default null,p_note text default '')
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_group public.group_buys%rowtype;
begin
 select * into v_group from public.group_buys where id=p_group_buy_id and supplier_id=auth.uid() for update;
 if not found then raise exception 'Предложение не найдено'; end if;
 if v_group.status not in ('offered','countered') then raise exception 'Предложение сейчас нельзя изменить'; end if;
 if p_decision='accept' then
  update public.group_buys set status='accepted',responded_at=now(),offer_note=left(coalesce(p_note,''),500) where id=p_group_buy_id;
 elsif p_decision='decline' then
  update public.group_buys set status='declined',responded_at=now(),offer_note=left(coalesce(p_note,''),500) where id=p_group_buy_id;
 elsif p_decision='counter' then
  if p_counter_price is null or p_counter_price<=0 or p_counter_qty is null or p_counter_qty<=0 then raise exception 'Укажите встречную цену и объём'; end if;
  update public.group_buys set status='countered',counter_price=p_counter_price,counter_target_qty=p_counter_qty,responded_at=now(),offer_note=left(coalesce(p_note,''),500) where id=p_group_buy_id;
 else raise exception 'Неизвестное решение'; end if;
end $$;

revoke all on function public.create_buyer_group_buy(uuid,numeric,numeric,integer,timestamptz) from public,anon;
revoke all on function public.join_group_buy(uuid,numeric) from public,anon;
revoke all on function public.submit_group_buy_offer(uuid) from public,anon;
revoke all on function public.respond_group_buy_offer(uuid,text,numeric,numeric,text) from public,anon;
grant execute on function public.create_buyer_group_buy(uuid,numeric,numeric,integer,timestamptz) to authenticated;
grant execute on function public.join_group_buy(uuid,numeric) to authenticated;
grant execute on function public.submit_group_buy_offer(uuid) to authenticated;
grant execute on function public.respond_group_buy_offer(uuid,text,numeric,numeric,text) to authenticated;
