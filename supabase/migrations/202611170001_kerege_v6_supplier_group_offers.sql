-- KEREGE 6.0: supplier-defined bulk offers with independent buyer groups.
create table if not exists public.group_buy_offers (
 id uuid primary key default gen_random_uuid(),
 supplier_id uuid not null references public.supplier_public_profiles(id) on delete cascade,
 product_id uuid not null references public.products(id) on delete restrict,
 title text not null,
 unit text not null,
 regular_price numeric(14,2) not null check(regular_price>0),
 agreed_price numeric(14,2) not null check(agreed_price>0),
 min_qty numeric(14,3) not null check(min_qty>0),
 max_qty numeric(14,3) not null check(max_qty>=min_qty and max_qty<=min_qty*1.5),
 city text not null default 'Бишкек',
 ends_at timestamptz not null,
 status text not null default 'active' check(status in ('active','paused','closed','cancelled')),
 created_at timestamptz not null default now()
);
alter table public.group_buys add column if not exists offer_id uuid references public.group_buy_offers(id) on delete cascade;
alter table public.group_buys add column if not exists max_qty numeric(14,3);
alter table public.group_buys add column if not exists final_note text not null default '';
alter table public.group_buys alter column target_people set default 2;
create index if not exists group_buy_offers_active_idx on public.group_buy_offers(status,ends_at desc);
create index if not exists group_buys_offer_idx on public.group_buys(offer_id,status,created_at desc);
alter table public.group_buy_offers enable row level security;
drop policy if exists group_buy_offers_public_read on public.group_buy_offers;
create policy group_buy_offers_public_read on public.group_buy_offers for select to authenticated using(status='active' or supplier_id=auth.uid());
drop policy if exists group_buy_offers_supplier_insert on public.group_buy_offers;
create policy group_buy_offers_supplier_insert on public.group_buy_offers for insert to authenticated with check(supplier_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='supplier'));
drop policy if exists group_buy_offers_supplier_update on public.group_buy_offers;
create policy group_buy_offers_supplier_update on public.group_buy_offers for update to authenticated using(supplier_id=auth.uid()) with check(supplier_id=auth.uid());
grant select on public.group_buy_offers to authenticated;
grant insert,update on public.group_buy_offers to authenticated;

create or replace function public.create_group_buy_offer(
 p_product_id uuid,p_agreed_price numeric,p_min_qty numeric,p_max_qty numeric,p_ends_at timestamptz
) returns uuid language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid:=auth.uid(); v_product public.products%rowtype; v_id uuid;
begin
 if v_user is null or not exists(select 1 from public.profiles where id=v_user and role='supplier') then raise exception 'Создавать предложения могут только поставщики'; end if;
 if p_agreed_price is null or p_agreed_price<=0 or p_min_qty is null or p_min_qty<=0 or p_max_qty is null or p_max_qty<p_min_qty or p_max_qty>p_min_qty*1.5 then raise exception 'Проверьте цену и объём: максимум — 150%% от минимума'; end if;
 if p_ends_at is null or p_ends_at<=now() then raise exception 'Укажите будущий срок действия'; end if;
 select * into v_product from public.products where id=p_product_id and supplier_id=v_user and is_active=true for share;
 if not found then raise exception 'Выберите свой опубликованный товар'; end if;
 if p_agreed_price>v_product.price then raise exception 'Оптовая цена не должна превышать обычную цену товара'; end if;
 insert into public.group_buy_offers(supplier_id,product_id,title,unit,regular_price,agreed_price,min_qty,max_qty,city,ends_at)
 values(v_user,v_product.id,v_product.name,v_product.unit,v_product.price,p_agreed_price,p_min_qty,p_max_qty,v_product.city,p_ends_at)
 returning id into v_id;
 return v_id;
end $$;

create or replace function public.create_group_from_offer(p_offer_id uuid,p_first_quantity numeric)
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid:=auth.uid(); v_offer public.group_buy_offers%rowtype; v_group uuid;
begin
 if v_user is null or not exists(select 1 from public.profiles where id=v_user and role='buyer') then raise exception 'Создавать группы могут только покупатели'; end if;
 if p_first_quantity is null or p_first_quantity<=0 then raise exception 'Укажите свой объём'; end if;
 select * into v_offer from public.group_buy_offers where id=p_offer_id and status='active' and ends_at>now() for share;
 if not found then raise exception 'Предложение недоступно или срок истёк'; end if;
 if p_first_quantity>v_offer.max_qty then raise exception 'Ваш объём превышает максимум группы'; end if;
 insert into public.group_buys(creator_id,supplier_id,product_id,offer_id,title,unit,price,target_qty,max_qty,committed_qty,target_people,city,ends_at,status)
 values(v_user,v_offer.supplier_id,v_offer.product_id,v_offer.id,v_offer.title,v_offer.unit,v_offer.agreed_price,v_offer.min_qty,v_offer.max_qty,0,2,v_offer.city,v_offer.ends_at,'open')
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
 if v_group.offer_id is not null and v_total>v_group.max_qty then raise exception 'Максимальный объём этой группы уже достигнут'; end if;
 if v_group.offer_id is null and v_total>v_group.target_qty then raise exception 'Количество превысит целевой объём группы'; end if;
 if v_member is null then insert into public.group_buy_members(group_buy_id,user_id,quantity) values(p_group_buy_id,v_user,p_quantity) returning id into v_member;
 else update public.group_buy_members set quantity=p_quantity,status='interested' where id=v_member; end if;
 update public.group_buys set committed_qty=v_total,
 status=case when v_total>=target_qty then 'target_reached' else 'open' end
 where id=p_group_buy_id;
 return v_member;
end $$;

create or replace function public.submit_group_buy_offer(p_group_buy_id uuid)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_group public.group_buys%rowtype;
begin
 select * into v_group from public.group_buys where id=p_group_buy_id for update;
 if not found or v_group.creator_id<>auth.uid() then raise exception 'Отправить предложение может только создатель группы'; end if;
 if v_group.offer_id is null then raise exception 'Это устаревшая группа старого формата'; end if;
 if v_group.status<>'target_reached' or v_group.committed_qty<v_group.target_qty then raise exception 'Сначала наберите минимальный объём'; end if;
 update public.group_buys set status='offered',offer_sent_at=now(),responded_at=null where id=p_group_buy_id;
end $$;

create or replace function public.respond_group_buy_offer(p_group_buy_id uuid,p_decision text,p_counter_price numeric default null,p_counter_qty numeric default null,p_note text default '')
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_group public.group_buys%rowtype;
begin
 select * into v_group from public.group_buys where id=p_group_buy_id and supplier_id=auth.uid() for update;
 if not found or v_group.offer_id is null then raise exception 'Предложение не найдено'; end if;
 if v_group.status<>'offered' then raise exception 'Предложение сейчас нельзя изменить'; end if;
 if p_decision='accept' then update public.group_buys set status='accepted',responded_at=now(),final_note=left(coalesce(p_note,''),500) where id=p_group_buy_id;
 elsif p_decision='decline' then update public.group_buys set status='declined',responded_at=now(),final_note=left(coalesce(p_note,''),500) where id=p_group_buy_id;
 else raise exception 'Доступны только принятие или отказ'; end if;
end $$;

create or replace function public.resolve_expired_group_buy(p_group_buy_id uuid,p_action text,p_new_ends_at timestamptz default null)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_group public.group_buys%rowtype;
begin
 select * into v_group from public.group_buys where id=p_group_buy_id and supplier_id=auth.uid() for update;
 if not found or v_group.offer_id is null then raise exception 'Группа не найдена'; end if;
 if v_group.ends_at>now() then raise exception 'Срок набора ещё не истёк'; end if;
 if v_group.status not in ('open','target_reached') then raise exception 'Эту группу уже нельзя изменить'; end if;
 if p_action='cancel' then update public.group_buys set status='cancelled',final_note='Поставщик отменил группу после окончания срока' where id=p_group_buy_id;
 elsif p_action='extend' then
  if p_new_ends_at is null or p_new_ends_at<=now() then raise exception 'Укажите новую будущую дату'; end if;
  update public.group_buys set ends_at=p_new_ends_at,status=case when committed_qty>=target_qty then 'target_reached' else 'open' end where id=p_group_buy_id;
 elsif p_action='accept_current' then
  if v_group.committed_qty<v_group.target_qty then raise exception 'Минимальный объём ещё не набран'; end if;
  update public.group_buys set status='offered',offer_sent_at=now(),final_note='Поставщику предложен фактически набранный объём' where id=p_group_buy_id;
 else raise exception 'Неизвестное действие'; end if;
end $$;

revoke all on function public.create_group_buy_offer(uuid,numeric,numeric,numeric,timestamptz) from public,anon;
revoke all on function public.create_group_from_offer(uuid,numeric) from public,anon;
revoke all on function public.join_group_buy(uuid,numeric) from public,anon;
revoke all on function public.submit_group_buy_offer(uuid) from public,anon;
revoke all on function public.respond_group_buy_offer(uuid,text,numeric,numeric,text) from public,anon;
revoke all on function public.resolve_expired_group_buy(uuid,text,timestamptz) from public,anon;
grant execute on function public.create_group_buy_offer(uuid,numeric,numeric,numeric,timestamptz) to authenticated;
grant execute on function public.create_group_from_offer(uuid,numeric) to authenticated;
grant execute on function public.join_group_buy(uuid,numeric) to authenticated;
grant execute on function public.submit_group_buy_offer(uuid) to authenticated;
grant execute on function public.respond_group_buy_offer(uuid,text,numeric,numeric,text) to authenticated;
grant execute on function public.resolve_expired_group_buy(uuid,text,timestamptz) to authenticated;
