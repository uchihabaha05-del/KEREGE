-- KEREGE 7.0: group-buy deposit protection, per-buyer delivery confirmation and disputes.
-- This migration records payment states only. A licensed payment provider/webhook is required
-- to move real money; never mark a payment as held/released from the browser client.

alter table public.group_buys
  add column if not exists accepted_at timestamptz,
  add column if not exists delivery_review_status text not null default 'not_started'
    check (delivery_review_status in ('not_started','in_progress','disputed','release_eligible','closed'));

alter table public.group_buy_members
  add column if not exists deposit_required numeric(14,2),
  add column if not exists deposit_deadline timestamptz,
  add column if not exists confirmed_at timestamptz;

create table if not exists public.group_buy_deposits (
  id uuid primary key default gen_random_uuid(),
  group_buy_id uuid not null references public.group_buys(id) on delete restrict,
  member_id uuid not null unique references public.group_buy_members(id) on delete restrict,
  buyer_id uuid not null references public.profiles(id) on delete restrict,
  share_amount numeric(14,2) not null check (share_amount > 0),
  deposit_amount numeric(14,2) not null check (deposit_amount > 0),
  currency text not null default 'KGS' check (currency='KGS'),
  status text not null default 'pending'
    check (status in ('pending','held','refund_pending','refunded','release_pending','released','disputed','cancelled')),
  provider text,
  provider_payment_id text unique,
  provider_refund_id text unique,
  paid_at timestamptz,
  refunded_at timestamptz,
  released_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists group_buy_deposits_group_status_idx
  on public.group_buy_deposits(group_buy_id,status);
create index if not exists group_buy_deposits_buyer_created_idx
  on public.group_buy_deposits(buyer_id,created_at desc);

create table if not exists public.group_buy_deliveries (
  id uuid primary key default gen_random_uuid(),
  group_buy_id uuid not null references public.group_buys(id) on delete restrict,
  member_id uuid not null unique references public.group_buy_members(id) on delete restrict,
  supplier_id uuid not null references public.profiles(id) on delete restrict,
  carrier text not null default '',
  tracking_number text not null default '',
  proof_url text not null default '',
  shipped_at timestamptz,
  delivered_at timestamptz,
  buyer_confirmed_at timestamptz,
  review_deadline timestamptz,
  status text not null default 'not_shipped'
    check (status in ('not_shipped','shipped','delivered','confirmed','disputed','review_required')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists group_buy_deliveries_group_status_idx
  on public.group_buy_deliveries(group_buy_id,status);

create table if not exists public.group_buy_disputes (
  id uuid primary key default gen_random_uuid(),
  group_buy_id uuid not null references public.group_buys(id) on delete restrict,
  member_id uuid not null references public.group_buy_members(id) on delete restrict,
  buyer_id uuid not null references public.profiles(id) on delete restrict,
  reason text not null check (reason in ('not_received','damaged','missing_items','wrong_item','other')),
  details text not null default '' check (char_length(details)<=2000),
  evidence_urls text[] not null default '{}',
  status text not null default 'open' check (status in ('open','under_review','resolved_buyer','resolved_supplier','closed')),
  resolution_note text not null default '',
  resolved_by uuid references public.profiles(id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists group_buy_disputes_group_status_idx
  on public.group_buy_disputes(group_buy_id,status);

alter table public.group_buy_deposits enable row level security;
alter table public.group_buy_deliveries enable row level security;
alter table public.group_buy_disputes enable row level security;
revoke all on public.group_buy_deposits,public.group_buy_deliveries,public.group_buy_disputes from anon,authenticated;
grant select on public.group_buy_deposits,public.group_buy_deliveries,public.group_buy_disputes to authenticated;

drop policy if exists group_buy_deposits_party_read on public.group_buy_deposits;
create policy group_buy_deposits_party_read on public.group_buy_deposits for select to authenticated
using (buyer_id=auth.uid() or exists(select 1 from public.group_buys g where g.id=group_buy_id and g.supplier_id=auth.uid()) or public.is_kerege_admin());

drop policy if exists group_buy_deliveries_party_read on public.group_buy_deliveries;
create policy group_buy_deliveries_party_read on public.group_buy_deliveries for select to authenticated
using (supplier_id=auth.uid() or exists(select 1 from public.group_buy_members m where m.id=member_id and m.user_id=auth.uid()) or public.is_kerege_admin());

drop policy if exists group_buy_disputes_party_read on public.group_buy_disputes;
create policy group_buy_disputes_party_read on public.group_buy_disputes for select to authenticated
using (buyer_id=auth.uid() or exists(select 1 from public.group_buys g where g.id=group_buy_id and g.supplier_id=auth.uid()) or public.is_kerege_admin());

-- Create a 5% deposit record after the supplier accepts the group.
-- Deadline is 24 hours from supplier acceptance; the amount is rounded to tiyin.
create or replace function public.create_group_buy_deposit(p_group_buy_id uuid)
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare
  v_user uuid:=auth.uid();
  v_group public.group_buys%rowtype;
  v_member public.group_buy_members%rowtype;
  v_deposit uuid;
  v_share numeric(14,2);
  v_amount numeric(14,2);
begin
  if v_user is null then raise exception 'Требуется авторизация'; end if;
  select * into v_group from public.group_buys where id=p_group_buy_id for update;
  if not found or v_group.status<>'accepted' then raise exception 'Поставщик ещё не принял группу'; end if;
  select * into v_member from public.group_buy_members
   where group_buy_id=p_group_buy_id and user_id=v_user and status<>'withdrawn' for update;
  if not found then raise exception 'Вы не участвуете в этой группе'; end if;
  if v_group.accepted_at is null then
    update public.group_buys set accepted_at=coalesce(responded_at,now()) where id=p_group_buy_id returning * into v_group;
  end if;
  if now()>v_group.accepted_at+interval '24 hours' then raise exception 'Срок оплаты депозита истёк'; end if;
  v_share:=round(v_member.quantity*v_group.price,2);
  v_amount:=round(v_share*0.05,2);
  if v_amount<=0 then raise exception 'Сумма депозита некорректна'; end if;
  update public.group_buy_members set deposit_required=v_amount,deposit_deadline=v_group.accepted_at+interval '24 hours'
   where id=v_member.id;
  insert into public.group_buy_deposits(group_buy_id,member_id,buyer_id,share_amount,deposit_amount)
  values(p_group_buy_id,v_member.id,v_user,v_share,v_amount)
  on conflict(member_id) do update set share_amount=excluded.share_amount,deposit_amount=excluded.deposit_amount
    where public.group_buy_deposits.status in ('pending','cancelled')
  returning id into v_deposit;
  if v_deposit is null then
    select id into v_deposit from public.group_buy_deposits where member_id=v_member.id;
  end if;
  return v_deposit;
end $$;

-- Called only by a trusted payment-provider webhook using service_role.
create or replace function public.confirm_group_buy_deposit_payment(
 p_deposit_id uuid,p_provider text,p_provider_payment_id text
) returns void language plpgsql security definer set search_path=public,auth as $$
declare v_deposit public.group_buy_deposits%rowtype; v_group uuid;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Только платёжный webhook может подтвердить оплату'; end if;
 if nullif(trim(p_provider),'') is null or nullif(trim(p_provider_payment_id),'') is null then raise exception 'Не указан платёжный идентификатор'; end if;
 select * into v_deposit from public.group_buy_deposits where id=p_deposit_id for update;
 if not found then raise exception 'Депозит не найден'; end if;
 if v_deposit.status='held' then return; end if;
 if v_deposit.status<>'pending' then raise exception 'Этот депозит нельзя подтвердить'; end if;
 update public.group_buy_deposits set status='held',provider=p_provider,provider_payment_id=p_provider_payment_id,paid_at=now(),updated_at=now() where id=p_deposit_id;
 update public.group_buy_members set confirmed_at=now() where id=v_deposit.member_id;
 update public.group_buys set delivery_review_status='in_progress' where id=v_deposit.group_buy_id;
end $$;

-- A buyer may leave before shipment. The deposit is fully refunded through provider workflow.
create or replace function public.withdraw_group_buy_before_shipment(p_group_buy_id uuid)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_member public.group_buy_members%rowtype; v_delivery public.group_buy_deliveries%rowtype;
begin
 select * into v_member from public.group_buy_members
  where group_buy_id=p_group_buy_id and user_id=auth.uid() and status<>'withdrawn' for update;
 if not found then raise exception 'Активное участие не найдено'; end if;
 select * into v_delivery from public.group_buy_deliveries where member_id=v_member.id;
 if found and v_delivery.status not in ('not_shipped') then raise exception 'После отправки товара выход оформляется через спор'; end if;
 update public.group_buy_members set status='withdrawn' where id=v_member.id;
 update public.group_buys set committed_qty=greatest(0,committed_qty-v_member.quantity),
   status=case when status in ('open','target_reached') then 'open' else status end
 where id=p_group_buy_id;
 update public.group_buy_deposits set status='refund_pending',updated_at=now()
  where member_id=v_member.id and status='held';
 update public.group_buy_deposits set status='cancelled',updated_at=now()
  where member_id=v_member.id and status='pending';
end $$;

-- Supplier records shipment per buyer. This does not release any deposit.
create or replace function public.record_group_buy_shipment(
 p_member_id uuid,p_carrier text,p_tracking_number text,p_proof_url text default ''
) returns uuid language plpgsql security definer set search_path=public,auth as $$
declare v_member public.group_buy_members%rowtype; v_group public.group_buys%rowtype; v_id uuid;
begin
 select * into v_member from public.group_buy_members where id=p_member_id and status<>'withdrawn' for update;
 if not found then raise exception 'Участник не найден'; end if;
 select * into v_group from public.group_buys where id=v_member.group_buy_id and supplier_id=auth.uid() and status='accepted' for update;
 if not found then raise exception 'Нет принятой группы для этого поставщика'; end if;
 if not exists(select 1 from public.group_buy_deposits where member_id=p_member_id and status='held') then raise exception 'Депозит покупателя ещё не подтверждён'; end if;
 if nullif(trim(p_tracking_number),'') is null then raise exception 'Укажите номер отслеживания или код доставки'; end if;
 insert into public.group_buy_deliveries(group_buy_id,member_id,supplier_id,carrier,tracking_number,proof_url,shipped_at,review_deadline,status)
 values(v_group.id,p_member_id,auth.uid(),left(coalesce(p_carrier,''),100),left(p_tracking_number,200),left(coalesce(p_proof_url,''),1000),now(),now()+interval '72 hours','shipped')
 on conflict(member_id) do update set carrier=excluded.carrier,tracking_number=excluded.tracking_number,proof_url=excluded.proof_url,shipped_at=excluded.shipped_at,review_deadline=excluded.review_deadline,status='shipped',updated_at=now()
 returning id into v_id;
 return v_id;
end $$;

create or replace function public.confirm_group_buy_delivery(p_member_id uuid)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_delivery public.group_buy_deliveries%rowtype; v_group uuid;
begin
 select d.* into v_delivery from public.group_buy_deliveries d
  join public.group_buy_members m on m.id=d.member_id
  where d.member_id=p_member_id and m.user_id=auth.uid() for update of d;
 if not found then raise exception 'Доставка не найдена'; end if;
 if v_delivery.status not in ('shipped','delivered') then raise exception 'Нельзя подтвердить эту доставку'; end if;
 update public.group_buy_deliveries set status='confirmed',delivered_at=coalesce(delivered_at,now()),buyer_confirmed_at=now(),updated_at=now() where id=v_delivery.id;
 update public.group_buy_deposits set status='release_pending',updated_at=now()
  where member_id=p_member_id and status='held';
 v_group:=v_delivery.group_buy_id;
 if not exists(
   select 1 from public.group_buy_members m
   where m.group_buy_id=v_group and m.status<>'withdrawn'
     and not exists(select 1 from public.group_buy_deliveries d where d.member_id=m.id and d.status='confirmed')
 ) and not exists(select 1 from public.group_buy_disputes s where s.group_buy_id=v_group and s.status in ('open','under_review')) then
   update public.group_buys set delivery_review_status='release_eligible' where id=v_group;
 end if;
end $$;

create or replace function public.open_group_buy_dispute(
 p_member_id uuid,p_reason text,p_details text,p_evidence_urls text[] default '{}'
) returns uuid language plpgsql security definer set search_path=public,auth as $$
declare v_member public.group_buy_members%rowtype; v_delivery public.group_buy_deliveries%rowtype; v_id uuid;
begin
 select * into v_member from public.group_buy_members where id=p_member_id and user_id=auth.uid() and status<>'withdrawn' for update;
 if not found then raise exception 'Участие не найдено'; end if;
 if p_reason not in ('not_received','damaged','missing_items','wrong_item','other') then raise exception 'Выберите причину спора'; end if;
 if char_length(coalesce(p_details,''))>2000 then raise exception 'Описание слишком длинное'; end if;
 select * into v_delivery from public.group_buy_deliveries where member_id=p_member_id;
 if not found or v_delivery.status not in ('shipped','delivered','review_required') then raise exception 'Сейчас нельзя открыть спор по доставке'; end if;
 insert into public.group_buy_disputes(group_buy_id,member_id,buyer_id,reason,details,evidence_urls)
 values(v_member.group_buy_id,p_member_id,auth.uid(),p_reason,left(coalesce(p_details,''),2000),coalesce(p_evidence_urls,'{}')) returning id into v_id;
 update public.group_buy_deliveries set status='disputed',updated_at=now() where member_id=p_member_id;
 update public.group_buy_deposits set status='disputed',updated_at=now() where member_id=p_member_id and status in ('held','release_pending');
 update public.group_buys set delivery_review_status='disputed' where id=v_member.group_buy_id;
 return v_id;
end $$;

-- Admin resolves a dispute. Refund/release still requires provider-side settlement confirmation.
create or replace function public.resolve_group_buy_dispute(
 p_dispute_id uuid,p_resolution text,p_note text
) returns void language plpgsql security definer set search_path=public,auth as $$
declare v_dispute public.group_buy_disputes%rowtype;
begin
 if not public.is_kerege_admin() then raise exception 'Доступ разрешён только администратору KEREGE'; end if;
 if p_resolution not in ('buyer','supplier') then raise exception 'Неизвестное решение'; end if;
 select * into v_dispute from public.group_buy_disputes where id=p_dispute_id for update;
 if not found or v_dispute.status not in ('open','under_review') then raise exception 'Спор уже закрыт или не найден'; end if;
 update public.group_buy_disputes set status=case when p_resolution='buyer' then 'resolved_buyer' else 'resolved_supplier' end,
  resolution_note=left(coalesce(p_note,''),2000),resolved_by=auth.uid(),resolved_at=now() where id=p_dispute_id;
 if p_resolution='buyer' then
   update public.group_buy_deposits set status='refund_pending',updated_at=now() where member_id=v_dispute.member_id and status='disputed';
 else
   update public.group_buy_deposits set status='release_pending',updated_at=now() where member_id=v_dispute.member_id and status='disputed';
   update public.group_buy_deliveries set status='confirmed',buyer_confirmed_at=coalesce(buyer_confirmed_at,now()),updated_at=now() where member_id=v_dispute.member_id;
 end if;
 if not exists(select 1 from public.group_buy_disputes where group_buy_id=v_dispute.group_buy_id and status in ('open','under_review')) then
   if not exists(select 1 from public.group_buy_members m where m.group_buy_id=v_dispute.group_buy_id and m.status<>'withdrawn'
     and not exists(select 1 from public.group_buy_deliveries d where d.member_id=m.id and d.status='confirmed')) then
     update public.group_buys set delivery_review_status='release_eligible' where id=v_dispute.group_buy_id;
   else
     update public.group_buys set delivery_review_status='in_progress' where id=v_dispute.group_buy_id;
   end if;
 end if;
end $$;

-- Provider callbacks only: confirm that an actual refund or platform settlement completed.
create or replace function public.confirm_group_buy_deposit_settlement(
 p_deposit_id uuid,p_action text,p_provider_reference text
) returns void language plpgsql security definer set search_path=public,auth as $$
declare v_deposit public.group_buy_deposits%rowtype;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Только платёжный webhook может подтвердить расчёт'; end if;
 if p_action not in ('refund','release') then raise exception 'Неизвестный тип расчёта'; end if;
 if nullif(trim(p_provider_reference),'') is null then raise exception 'Не указан идентификатор расчёта'; end if;
 select * into v_deposit from public.group_buy_deposits where id=p_deposit_id for update;
 if not found then raise exception 'Депозит не найден'; end if;
 if p_action='refund' then
   if v_deposit.status not in ('refund_pending','disputed') then raise exception 'Возврат сейчас не ожидается'; end if;
   update public.group_buy_deposits set status='refunded',provider_refund_id=p_provider_reference,refunded_at=now(),updated_at=now() where id=p_deposit_id;
 else
   if v_deposit.status<>'release_pending' then raise exception 'Перевод комиссии ещё не разрешён'; end if;
   if not exists(select 1 from public.group_buys where id=v_deposit.group_buy_id and delivery_review_status='release_eligible') then raise exception 'Группа ещё не прошла подтверждение всех доставок'; end if;
   update public.group_buy_deposits set status='released',provider_refund_id=p_provider_reference,released_at=now(),updated_at=now() where id=p_deposit_id;
 end if;
end $$;

-- Expired delivery confirmation is NOT treated as successful delivery.
create or replace function public.flag_unconfirmed_group_buy_deliveries()
returns integer language plpgsql security definer set search_path=public,auth as $$
declare v_count integer;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Только серверная задача может запускать проверку сроков'; end if;
 update public.group_buy_deliveries set status='review_required',updated_at=now()
 where status in ('shipped','delivered') and review_deadline is not null and review_deadline<now();
 get diagnostics v_count=row_count;
 return v_count;
end $$;

revoke all on function public.create_group_buy_deposit(uuid) from public,anon;
revoke all on function public.confirm_group_buy_deposit_payment(uuid,text,text) from public,anon,authenticated;
revoke all on function public.withdraw_group_buy_before_shipment(uuid) from public,anon;
revoke all on function public.record_group_buy_shipment(uuid,text,text,text) from public,anon;
revoke all on function public.confirm_group_buy_delivery(uuid) from public,anon;
revoke all on function public.open_group_buy_dispute(uuid,text,text,text[]) from public,anon;
revoke all on function public.resolve_group_buy_dispute(uuid,text,text) from public,anon;
revoke all on function public.confirm_group_buy_deposit_settlement(uuid,text,text) from public,anon,authenticated;
revoke all on function public.flag_unconfirmed_group_buy_deliveries() from public,anon,authenticated;
grant execute on function public.create_group_buy_deposit(uuid) to authenticated;
grant execute on function public.withdraw_group_buy_before_shipment(uuid) to authenticated;
grant execute on function public.record_group_buy_shipment(uuid,text,text,text) to authenticated;
grant execute on function public.confirm_group_buy_delivery(uuid) to authenticated;
grant execute on function public.open_group_buy_dispute(uuid,text,text,text[]) to authenticated;
grant execute on function public.resolve_group_buy_dispute(uuid,text,text) to authenticated;
grant execute on function public.confirm_group_buy_deposit_payment(uuid,text,text) to service_role;
grant execute on function public.confirm_group_buy_deposit_settlement(uuid,text,text) to service_role;
grant execute on function public.flag_unconfirmed_group_buy_deliveries() to service_role;


-- Capture the supplier's acceptance timestamp exactly once; never start the
-- 24-hour deposit window from the buyer's first page visit.
create or replace function public.set_group_buy_accepted_at()
returns trigger language plpgsql set search_path=public as $$
begin
 if new.status='accepted' and old.status is distinct from 'accepted' then
   new.accepted_at:=coalesce(new.accepted_at,new.responded_at,now());
 end if;
 return new;
end $$;
drop trigger if exists group_buy_accepted_at_stamp on public.group_buys;
create trigger group_buy_accepted_at_stamp before update of status on public.group_buys
for each row execute function public.set_group_buy_accepted_at();

-- Cancellation/refusal triggers full deposit refunds; pending deposits are cancelled.
create or replace function public.refund_group_buy_deposits_on_cancel()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.status in ('declined','cancelled') and old.status is distinct from new.status then
   update public.group_buy_deposits set
     status=case when status in ('held','disputed','release_pending') then 'refund_pending'
                 when status='pending' then 'cancelled' else status end,
     updated_at=now()
   where group_buy_id=new.id;
 end if;
 return new;
end $$;
drop trigger if exists group_buy_deposits_refund_on_cancel on public.group_buys;
create trigger group_buy_deposits_refund_on_cancel after update of status on public.group_buys
for each row execute function public.refund_group_buy_deposits_on_cancel();

revoke all on function public.set_group_buy_accepted_at() from public,anon,authenticated;
revoke all on function public.refund_group_buy_deposits_on_cancel() from public,anon,authenticated;
