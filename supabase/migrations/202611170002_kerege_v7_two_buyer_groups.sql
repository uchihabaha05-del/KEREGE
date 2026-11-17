-- KEREGE 7.0: limit each group purchase to exactly two buyer slots.
-- No deposit, escrow, or 5% platform fee is collected by this workflow.

alter table public.group_buys alter column target_people set default 2;
update public.group_buys set target_people=2 where offer_id is not null;

create or replace function public.join_group_buy(p_group_buy_id uuid,p_quantity numeric)
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare
 v_user uuid:=auth.uid();
 v_group public.group_buys%rowtype;
 v_member uuid;
 v_old numeric:=0;
 v_total numeric;
 v_people integer;
begin
 if v_user is null then raise exception 'Требуется авторизация'; end if;
 if p_quantity is null or p_quantity<=0 then raise exception 'Количество должно быть больше нуля'; end if;
 if not exists(select 1 from public.profiles where id=v_user and role='buyer') then raise exception 'Участвовать могут только покупатели'; end if;
 select * into v_group from public.group_buys where id=p_group_buy_id for update;
 if not found or v_group.status not in ('open','target_reached') or v_group.ends_at<=now() then raise exception 'Набор в группу закрыт'; end if;
 select id,quantity into v_member,v_old from public.group_buy_members
  where group_buy_id=p_group_buy_id and user_id=v_user and status<>'withdrawn' for update;
 select count(*) into v_people from public.group_buy_members where group_buy_id=p_group_buy_id and status<>'withdrawn';
 if v_member is null and v_people>=2 then raise exception 'В группе уже два покупателя. Свободных мест нет'; end if;
 v_total:=v_group.committed_qty-coalesce(v_old,0)+p_quantity;
 if v_group.offer_id is not null and v_total>v_group.max_qty then raise exception 'Максимальный объём этой группы уже достигнут'; end if;
 if v_group.offer_id is null and v_total>v_group.target_qty then raise exception 'Количество превысит целевой объём группы'; end if;
 if v_member is null then
   insert into public.group_buy_members(group_buy_id,user_id,quantity) values(p_group_buy_id,v_user,p_quantity) returning id into v_member;
   v_people:=v_people+1;
 else
   update public.group_buy_members set quantity=p_quantity,status='interested' where id=v_member;
 end if;
 update public.group_buys set committed_qty=v_total,
  target_people=2,
  status=case when v_total>=target_qty and v_people>=2 then 'target_reached' else 'open' end
 where id=p_group_buy_id;
 return v_member;
end $$;

create or replace function public.submit_group_buy_offer(p_group_buy_id uuid)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_group public.group_buys%rowtype; v_people integer;
begin
 select * into v_group from public.group_buys where id=p_group_buy_id for update;
 if not found or v_group.creator_id<>auth.uid() then raise exception 'Отправить предложение может только создатель группы'; end if;
 if v_group.offer_id is null then raise exception 'Это устаревшая группа старого формата'; end if;
 select count(*) into v_people from public.group_buy_members where group_buy_id=p_group_buy_id and status<>'withdrawn';
 if v_people<>2 then raise exception 'Для совместной закупки нужны ровно два покупателя'; end if;
 if v_group.status<>'target_reached' or v_group.committed_qty<v_group.target_qty then raise exception 'Наберите минимальный объём вдвоём'; end if;
 update public.group_buys set status='offered',offer_sent_at=now(),responded_at=null where id=p_group_buy_id;
end $$;

create or replace function public.leave_group_buy(p_group_buy_id uuid)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_group public.group_buys%rowtype; v_member public.group_buy_members%rowtype;
begin
 select * into v_group from public.group_buys where id=p_group_buy_id for update;
 if not found or v_group.status not in ('open','target_reached','offered') then
   raise exception 'Выйти можно только до принятия заказа поставщиком';
 end if;
 select * into v_member from public.group_buy_members
  where group_buy_id=p_group_buy_id and user_id=auth.uid() and status<>'withdrawn' for update;
 if not found then raise exception 'Вы не состоите в этой группе'; end if;
 update public.group_buy_members set status='withdrawn' where id=v_member.id;
 update public.group_buys set committed_qty=greatest(0,committed_qty-v_member.quantity),
  status='open',offer_sent_at=null,responded_at=null,target_people=2
 where id=p_group_buy_id;
end $$;

revoke all on function public.join_group_buy(uuid,numeric) from public,anon;
revoke all on function public.submit_group_buy_offer(uuid) from public,anon;
revoke all on function public.leave_group_buy(uuid) from public,anon;
grant execute on function public.join_group_buy(uuid,numeric) to authenticated;
grant execute on function public.submit_group_buy_offer(uuid) to authenticated;
grant execute on function public.leave_group_buy(uuid) to authenticated;
