-- KEREGE 3.0: supplier analytics, delivery timeline, reviews and admin foundation
-- Safe additive migration. Existing orders, chats and requests remain intact.

create table if not exists public.kerege_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.kerege_admins enable row level security;
revoke all on public.kerege_admins from anon, authenticated;

create or replace function public.is_kerege_admin()
returns boolean
language sql stable security definer
set search_path = public, auth
as $$
  select exists(select 1 from public.kerege_admins where user_id = auth.uid());
$$;
revoke all on function public.is_kerege_admin() from public, anon;
grant execute on function public.is_kerege_admin() to authenticated;

create table if not exists public.supplier_reviews (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete restrict,
  buyer_id uuid not null references public.profiles(id) on delete restrict,
  supplier_id uuid not null references public.supplier_public_profiles(id) on delete restrict,
  rating integer not null check (rating between 1 and 5),
  comment text not null default '' check (char_length(comment) <= 1200),
  created_at timestamptz not null default now()
);
create index if not exists supplier_reviews_supplier_created_idx
  on public.supplier_reviews(supplier_id, created_at desc);
alter table public.supplier_reviews enable row level security;
revoke all on public.supplier_reviews from anon, authenticated;
grant select on public.supplier_reviews to authenticated;
drop policy if exists supplier_reviews_parties_read on public.supplier_reviews;
create policy supplier_reviews_parties_read on public.supplier_reviews for select to authenticated
using (buyer_id = auth.uid() or supplier_id = auth.uid() or public.is_kerege_admin());

-- Expand existing in-app notification types for unified orders and reviews.
alter table public.user_notifications drop constraint if exists user_notifications_notification_type_check;
alter table public.user_notifications add constraint user_notifications_notification_type_check
  check (notification_type in ('new_order','order_status','new_message','unified_order','review'));

create or replace function public.submit_supplier_review(
  p_order_id uuid,
  p_rating integer,
  p_comment text default ''
)
returns uuid
language plpgsql security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_order public.orders%rowtype;
  v_review uuid;
begin
  if v_user is null then raise exception 'Требуется авторизация'; end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then raise exception 'Оценка должна быть от 1 до 5'; end if;
  if char_length(coalesce(p_comment,'')) > 1200 then raise exception 'Отзыв слишком длинный'; end if;
  select * into v_order from public.orders where id=p_order_id and buyer_id=v_user for update;
  if not found then raise exception 'Заказ не найден'; end if;
  if v_order.status <> 'completed' then raise exception 'Оценить можно только завершённый заказ'; end if;
  insert into public.supplier_reviews(order_id,buyer_id,supplier_id,rating,comment)
  values(p_order_id,v_user,v_order.supplier_id,p_rating,coalesce(trim(p_comment),'')) returning id into v_review;
  insert into public.user_notifications(user_id,request_id,notification_type,title,body)
  values(v_order.supplier_id,null,'review','Новый отзыв','Покупатель оставил оценку: '||p_rating||'/5');
  return v_review;
exception when unique_violation then
  raise exception 'Вы уже оставили отзыв на этот заказ';
end;
$$;
revoke all on function public.submit_supplier_review(uuid,integer,text) from public,anon;
grant execute on function public.submit_supplier_review(uuid,integer,text) to authenticated;

create or replace function public.get_supplier_analytics()
returns jsonb
language plpgsql stable security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_result jsonb;
begin
  if v_user is null then raise exception 'Требуется авторизация'; end if;
  if not exists(select 1 from public.profiles where id=v_user and role='supplier') then
    raise exception 'Доступ разрешён только поставщику';
  end if;
  select jsonb_build_object(
    'orders_total',count(*),
    'orders_active',count(*) filter(where status in ('new','accepted','preparing','ready_for_pickup','shipped','delivered')),
    'orders_completed',count(*) filter(where status='completed'),
    'orders_declined',count(*) filter(where status='declined'),
    'revenue_completed',coalesce(sum(total) filter(where status='completed'),0),
    'revenue_pending',coalesce(sum(total) filter(where status not in ('completed','declined','cancelled')),0),
    'average_rating',(select round(avg(rating)::numeric,2) from public.supplier_reviews where supplier_id=v_user),
    'reviews_count',(select count(*) from public.supplier_reviews where supplier_id=v_user)
  ) into v_result
  from public.orders where supplier_id=v_user;
  return v_result;
end;
$$;
revoke all on function public.get_supplier_analytics() from public,anon;
grant execute on function public.get_supplier_analytics() to authenticated;

create or replace function public.get_kerege_admin_overview()
returns jsonb
language plpgsql stable security definer
set search_path = public, auth
as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.is_kerege_admin() then
    raise exception 'Доступ разрешён только администратору KEREGE';
  end if;
  select jsonb_build_object(
    'users_total',(select count(*) from public.profiles),
    'buyers_total',(select count(*) from public.profiles where role='buyer'),
    'suppliers_total',(select count(*) from public.profiles where role='supplier'),
    'products_active',(select count(*) from public.products where is_active),
    'orders_total',(select count(*) from public.orders),
    'orders_active',(select count(*) from public.orders where status in ('new','accepted','preparing','ready_for_pickup','shipped','delivered')),
    'orders_completed',(select count(*) from public.orders where status='completed'),
    'orders_declined',(select count(*) from public.orders where status='declined'),
    'gross_completed',(select coalesce(sum(total),0) from public.orders where status='completed'),
    'reviews_total',(select count(*) from public.supplier_reviews)
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.get_kerege_admin_overview() from public,anon;
grant execute on function public.get_kerege_admin_overview() to authenticated;

-- Unified order changes create notifications for the other party.
create or replace function public.notify_unified_order_change()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare v_title text; v_body text;
begin
  if tg_op='INSERT' then
    insert into public.user_notifications(user_id,request_id,notification_type,title,body)
    values(new.supplier_id,null,'unified_order','Новый заказ KEREGE','Поступил заказ №'||new.order_number||'. Откройте раздел «Заказы».');
    return new;
  end if;
  if new.status is distinct from old.status then
    v_title := 'Изменился статус заказа №'||new.order_number;
    v_body := case new.status
      when 'accepted' then 'Поставщик принял заказ.'
      when 'preparing' then 'Поставщик начал собирать заказ.'
      when 'ready_for_pickup' then 'Заказ готов к самовывозу.'
      when 'shipped' then 'Заказ передан в доставку.'
      when 'delivered' then 'Заказ отмечен как доставленный.'
      when 'completed' then 'Заказ завершён.'
      when 'declined' then 'Поставщик отклонил заказ.'
      when 'cancelled' then 'Заказ отменён.'
      else 'Статус заказа обновлён.'
    end;
    insert into public.user_notifications(user_id,request_id,notification_type,title,body)
    values(new.buyer_id,null,'unified_order',v_title,v_body);
    if new.status in ('declined','completed') then
      insert into public.user_notifications(user_id,request_id,notification_type,title,body)
      values(new.supplier_id,null,'unified_order',v_title,'Статус заказа №'||new.order_number||' изменён.');
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists orders_notify_parties on public.orders;
create trigger orders_notify_parties after insert or update of status on public.orders
for each row execute function public.notify_unified_order_change();

-- Add review aggregate fields to public supplier profiles without exposing private buyer data.
create or replace view public.supplier_review_summary as
select supplier_id, round(avg(rating)::numeric,2) as average_rating, count(*)::bigint as reviews_count
from public.supplier_reviews group by supplier_id;
revoke all on public.supplier_review_summary from anon,authenticated;
grant select on public.supplier_review_summary to authenticated;
