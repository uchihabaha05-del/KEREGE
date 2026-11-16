-- KEREGE: order chat, in-app notifications and Realtime
-- Run after migrations 001, 002 and 003.

create table if not exists public.order_messages (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.purchase_requests(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  check (sender_id <> recipient_id)
);

create index if not exists order_messages_request_created_idx
  on public.order_messages(request_id, created_at asc);
create index if not exists order_messages_recipient_unread_idx
  on public.order_messages(recipient_id, read_at)
  where read_at is null;

create table if not exists public.user_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid references public.purchase_requests(id) on delete cascade,
  notification_type text not null check (notification_type in ('new_order','order_status','new_message')),
  title text not null,
  body text not null default '',
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists user_notifications_user_created_idx
  on public.user_notifications(user_id, created_at desc);
create index if not exists user_notifications_unread_idx
  on public.user_notifications(user_id, read_at)
  where read_at is null;

alter table public.order_messages enable row level security;
alter table public.user_notifications enable row level security;

revoke all on public.order_messages, public.user_notifications from anon, authenticated;
grant select, insert on public.order_messages to authenticated;
grant update (read_at) on public.order_messages to authenticated;
grant select, update on public.user_notifications to authenticated;

drop policy if exists order_messages_parties_read on public.order_messages;
create policy order_messages_parties_read
  on public.order_messages for select to authenticated
  using (
    sender_id = auth.uid() or recipient_id = auth.uid()
  );

drop policy if exists order_messages_parties_insert on public.order_messages;
create policy order_messages_parties_insert
  on public.order_messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.purchase_requests r
      where r.id = request_id
        and (r.buyer_id = auth.uid() or r.supplier_id = auth.uid())
        and (
          (r.buyer_id = auth.uid() and recipient_id = r.supplier_id)
          or
          (r.supplier_id = auth.uid() and recipient_id = r.buyer_id)
        )
    )
  );

drop policy if exists order_messages_recipient_mark_read on public.order_messages;
create policy order_messages_recipient_mark_read
  on public.order_messages for update to authenticated
  using (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());

drop policy if exists user_notifications_read_own on public.user_notifications;
create policy user_notifications_read_own
  on public.user_notifications for select to authenticated
  using (user_id = auth.uid());

drop policy if exists user_notifications_mark_own_read on public.user_notifications;
create policy user_notifications_mark_own_read
  on public.user_notifications for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create or replace function public.notify_purchase_request_parties()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.user_notifications(user_id, request_id, notification_type, title, body)
    values (
      new.supplier_id, new.id, 'new_order',
      'Новая заявка',
      'Покупатель отправил новую заявку на товар.'
    );
    return new;
  end if;

  if new.status is distinct from old.status then
    insert into public.user_notifications(user_id, request_id, notification_type, title, body)
    values (
      new.buyer_id, new.id, 'order_status',
      'Изменился статус заказа',
      case new.status
        when 'accepted' then 'Поставщик принял вашу заявку.'
        when 'declined' then 'Поставщик отклонил вашу заявку.'
        when 'completed' then 'Поставщик отметил заказ как завершённый.'
        when 'cancelled' then 'Заказ отменён.'
        else 'Статус заказа обновлён: ' || new.status
      end
    );
  end if;
  return new;
end;
$$;

drop trigger if exists purchase_request_notify_parties on public.purchase_requests;
create trigger purchase_request_notify_parties
  after insert or update of status on public.purchase_requests
  for each row execute function public.notify_purchase_request_parties();

create or replace function public.notify_order_message_recipient()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.user_notifications(user_id, request_id, notification_type, title, body)
  values (
    new.recipient_id, new.request_id, 'new_message',
    'Новое сообщение',
    left(new.body, 160)
  );
  return new;
end;
$$;

drop trigger if exists order_message_notify_recipient on public.order_messages;
create trigger order_message_notify_recipient
  after insert on public.order_messages
  for each row execute function public.notify_order_message_recipient();

-- Add both tables to Supabase Realtime if they are not already published.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'order_messages'
  ) then
    alter publication supabase_realtime add table public.order_messages;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'user_notifications'
  ) then
    alter publication supabase_realtime add table public.user_notifications;
  end if;
end $$;
