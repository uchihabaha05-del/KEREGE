-- KEREGE 5.1: expose only participant names and quantities, never profile contacts.
drop policy if exists profiles_group_members_read on public.profiles;
create or replace view public.group_buy_member_public as
select m.group_buy_id,m.user_id,p.full_name,m.quantity,m.status
from public.group_buy_members m
join public.profiles p on p.id=m.user_id
join public.group_buys g on g.id=m.group_buy_id
where m.status<>'withdrawn'
  and g.status in ('open','target_reached','offered','countered','accepted');
revoke all on public.group_buy_member_public from anon,authenticated;
grant select on public.group_buy_member_public to authenticated;
