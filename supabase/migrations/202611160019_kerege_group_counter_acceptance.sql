-- Allow the group creator to accept a supplier counteroffer and reopen recruitment if needed.
create or replace function public.accept_group_buy_counter(p_group_buy_id uuid)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_group public.group_buys%rowtype; v_people integer;
begin
 select * into v_group from public.group_buys where id=p_group_buy_id for update;
 if not found or v_group.creator_id<>auth.uid() then raise exception 'Только создатель группы может принять встречные условия'; end if;
 if v_group.status<>'countered' or v_group.counter_price is null or v_group.counter_target_qty is null then raise exception 'Встречное предложение недоступно'; end if;
 if v_group.counter_price<=0 or v_group.counter_target_qty<=0 then raise exception 'Некорректные условия поставщика'; end if;
 select count(*) into v_people from public.group_buy_members where group_buy_id=p_group_buy_id and status<>'withdrawn';
 update public.group_buys set price=counter_price,target_qty=counter_target_qty,
  status=case when committed_qty>=counter_target_qty and v_people>=target_people then 'target_reached' else 'open' end,
  counter_price=null,counter_target_qty=null,offer_sent_at=null,responded_at=null
 where id=p_group_buy_id;
end $$;
revoke all on function public.accept_group_buy_counter(uuid) from public,anon;
grant execute on function public.accept_group_buy_counter(uuid) to authenticated;
