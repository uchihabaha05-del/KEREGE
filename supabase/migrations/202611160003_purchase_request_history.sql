-- KEREGE order status history
-- Run once in Supabase SQL Editor after the two previous migrations.

create table if not exists public.purchase_request_history (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.purchase_requests(id) on delete cascade,
  event_type text not null check (event_type in ('created','status_changed','snapshot')),
  old_status text,
  new_status text not null,
  changed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists purchase_request_history_request_idx
  on public.purchase_request_history(request_id, created_at asc);

alter table public.purchase_request_history enable row level security;
revoke all on public.purchase_request_history from anon, authenticated;
grant select on public.purchase_request_history to authenticated;

drop policy if exists purchase_request_history_parties_read
  on public.purchase_request_history;
create policy purchase_request_history_parties_read
  on public.purchase_request_history
  for select to authenticated
  using (
    exists (
      select 1
      from public.purchase_requests r
      where r.id = request_id
        and (r.buyer_id = auth.uid() or r.supplier_id = auth.uid())
    )
  );

create or replace function public.log_purchase_request_history()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.purchase_request_history
      (request_id, event_type, old_status, new_status, changed_by)
    values
      (new.id, 'created', null, new.status, auth.uid());
    return new;
  end if;

  if new.status is distinct from old.status then
    insert into public.purchase_request_history
      (request_id, event_type, old_status, new_status, changed_by)
    values
      (new.id, 'status_changed', old.status, new.status, auth.uid());
  end if;
  return new;
end;
$$;

drop trigger if exists purchase_request_history_after_insert
  on public.purchase_requests;
create trigger purchase_request_history_after_insert
  after insert on public.purchase_requests
  for each row execute function public.log_purchase_request_history();

drop trigger if exists purchase_request_history_after_status_update
  on public.purchase_requests;
create trigger purchase_request_history_after_status_update
  after update of status on public.purchase_requests
  for each row execute function public.log_purchase_request_history();

-- Existing orders cannot have their past transitions reconstructed.
-- Record their current state as a snapshot, without inventing earlier events.
insert into public.purchase_request_history
  (request_id, event_type, old_status, new_status, changed_by)
select r.id, 'snapshot', null, r.status, null
from public.purchase_requests r
where not exists (
  select 1 from public.purchase_request_history h where h.request_id = r.id
);
