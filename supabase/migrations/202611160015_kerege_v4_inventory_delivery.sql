-- KEREGE 4.0: inventory control, safe order cancellation, buyer receipt confirmation and delivery details.
-- Additive migration. NULL stock_quantity means supplier has not enabled stock tracking for this item.

alter table public.products
  add column if not exists stock_quantity numeric(14,3),
  add column if not exists low_stock_threshold numeric(14,3) not null default 0;
alter table public.products
  drop constraint if exists products_stock_quantity_nonnegative,
  add constraint products_stock_quantity_nonnegative check(stock_quantity is null or stock_quantity >= 0),
  drop constraint if exists products_low_stock_nonnegative,
  add constraint products_low_stock_nonnegative check(low_stock_threshold >= 0);

alter table public.orders
  add column if not exists courier_name text not null default '',
  add column if not exists courier_phone text not null default '',
  add column if not exists tracking_code text not null default '',
  add column if not exists estimated_delivery_at timestamptz,
  add column if not exists buyer_confirmed_at timestamptz;

create or replace function public.set_supplier_product_stock(
  p_product_id uuid,
  p_stock_quantity numeric,
  p_low_stock_threshold numeric default 0
)
returns void
language plpgsql security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='supplier') then
    raise exception 'Доступ разрешён только поставщику';
  end if;
  if p_stock_quantity is not null and p_stock_quantity < 0 then raise exception 'Остаток не может быть отрицательным'; end if;
  if p_low_stock_threshold is null or p_low_stock_threshold < 0 then raise exception 'Порог остатка не может быть отрицательным'; end if;
  update public.products
    set stock_quantity=p_stock_quantity, low_stock_threshold=p_low_stock_threshold
    where id=p_product_id and supplier_id=auth.uid();
  if not found then raise exception 'Товар не найден'; end if;
end;
$$;
revoke all on function public.set_supplier_product_stock(uuid,numeric,numeric) from public,anon;
grant execute on function public.set_supplier_product_stock(uuid,numeric,numeric) to authenticated;

-- Decrease tracked stock atomically as order lines are inserted.
create or replace function public.decrement_stock_for_order_item()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare v_stock numeric(14,3);
begin
  if new.product_id is null then return new; end if;
  update public.products
    set stock_quantity=stock_quantity-new.quantity
    where id=new.product_id and stock_quantity is not null and stock_quantity >= new.quantity
    returning stock_quantity into v_stock;
  if found then return new; end if;
  if exists(select 1 from public.products where id=new.product_id and stock_quantity is null) then return new; end if;
  raise exception 'Недостаточно остатка товара "%". Обновите корзину или свяжитесь с поставщиком.',new.product_name;
end;
$$;
drop trigger if exists order_items_decrement_stock on public.order_items;
create trigger order_items_decrement_stock before insert on public.order_items
for each row execute function public.decrement_stock_for_order_item();

-- Restore tracked inventory exactly once when supplier declines or buyer cancels.
create or replace function public.restore_stock_for_cancelled_order()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if old.status not in ('declined','cancelled') and new.status in ('declined','cancelled') then
    update public.products p
      set stock_quantity=p.stock_quantity+oi.quantity
      from public.order_items oi
      where oi.order_id=new.id and oi.product_id=p.id and p.stock_quantity is not null;
  end if;
  return new;
end;
$$;
drop trigger if exists orders_restore_stock on public.orders;
create trigger orders_restore_stock after update of status on public.orders
for each row execute function public.restore_stock_for_cancelled_order();

-- Replace supplier transition RPC: suppliers cannot self-complete delivered orders.
create or replace function public.set_supplier_order_status(p_order_id uuid,p_new_status text,p_note text default '')
returns void
language plpgsql security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_order public.orders%rowtype;
  v_allowed boolean := false;
begin
  if v_user is null then raise exception 'Требуется авторизация'; end if;
  if not exists(select 1 from public.profiles where id=v_user and role='supplier') then
    raise exception 'Доступ разрешён только поставщику';
  end if;
  select * into v_order from public.orders where id=p_order_id and supplier_id=v_user for update;
  if not found then raise exception 'Заказ не найден'; end if;
  v_allowed := (v_order.status='new' and p_new_status in ('accepted','declined'))
    or (v_order.status='accepted' and p_new_status in ('preparing','ready_for_pickup','shipped'))
    or (v_order.status='preparing' and p_new_status in ('ready_for_pickup','shipped'))
    or (v_order.status='shipped' and p_new_status='delivered');
  if not v_allowed then raise exception 'Недопустимый переход статуса: % → %',v_order.status,p_new_status; end if;
  if v_order.delivery_method='pickup' and p_new_status in ('shipped','delivered') then
    raise exception 'Для самовывоза используйте статус «Готов к выдаче»';
  end if;
  if v_order.delivery_method='supplier_delivery' and p_new_status='ready_for_pickup' then
    raise exception 'Для доставки используйте передачу заказа в доставку';
  end if;
  update public.orders set status=p_new_status,updated_at=now(),
    accepted_at=case when p_new_status='accepted' then now() else accepted_at end,
    shipped_at=case when p_new_status='shipped' then now() else shipped_at end,
    delivered_at=case when p_new_status='delivered' then now() else delivered_at end
  where id=p_order_id;
  insert into public.order_status_events(order_id,old_status,new_status,note,changed_by)
  values(p_order_id,v_order.status,p_new_status,coalesce(p_note,''),v_user);
  update public.purchase_requests set status=
    case p_new_status when 'accepted' then 'accepted' when 'declined' then 'declined' else status end
  where id in (select legacy_request_id from public.order_items where order_id=p_order_id and legacy_request_id is not null)
    and p_new_status in ('accepted','declined');
end;
$$;
revoke all on function public.set_supplier_order_status(uuid,text,text) from public,anon;
grant execute on function public.set_supplier_order_status(uuid,text,text) to authenticated;

create or replace function public.cancel_buyer_order(p_order_id uuid,p_reason text default '')
returns void
language plpgsql security definer
set search_path = public, auth
as $$
declare v_order public.orders%rowtype; v_user uuid:=auth.uid();
begin
  if v_user is null then raise exception 'Требуется авторизация'; end if;
  select * into v_order from public.orders where id=p_order_id and buyer_id=v_user for update;
  if not found then raise exception 'Заказ не найден'; end if;
  if v_order.status not in ('new','accepted') then
    raise exception 'Отменить можно только новый или ещё не собранный заказ';
  end if;
  update public.orders set status='cancelled',updated_at=now() where id=p_order_id;
  insert into public.order_status_events(order_id,old_status,new_status,note,changed_by)
  values(p_order_id,v_order.status,'cancelled',left(coalesce(p_reason,''),500),v_user);
  update public.purchase_requests set status='cancelled'
  where id in (select legacy_request_id from public.order_items where order_id=p_order_id and legacy_request_id is not null);
end;
$$;
revoke all on function public.cancel_buyer_order(uuid,text) from public,anon;
grant execute on function public.cancel_buyer_order(uuid,text) to authenticated;

create or replace function public.confirm_buyer_order_received(p_order_id uuid)
returns void
language plpgsql security definer
set search_path = public, auth
as $$
declare v_order public.orders%rowtype; v_user uuid:=auth.uid();
begin
  if v_user is null then raise exception 'Требуется авторизация'; end if;
  select * into v_order from public.orders where id=p_order_id and buyer_id=v_user for update;
  if not found then raise exception 'Заказ не найден'; end if;
  if v_order.status not in ('delivered','ready_for_pickup') then
    raise exception 'Подтвердить получение можно только после доставки или готовности к самовывозу';
  end if;
  update public.orders set status='completed',completed_at=now(),buyer_confirmed_at=now(),updated_at=now()
  where id=p_order_id;
  insert into public.order_status_events(order_id,old_status,new_status,note,changed_by)
  values(p_order_id,v_order.status,'completed','Покупатель подтвердил получение заказа.',v_user);
  update public.purchase_requests set status='completed'
  where id in (select legacy_request_id from public.order_items where order_id=p_order_id and legacy_request_id is not null);
end;
$$;
revoke all on function public.confirm_buyer_order_received(uuid) from public,anon;
grant execute on function public.confirm_buyer_order_received(uuid) to authenticated;

create or replace function public.set_supplier_delivery_details(
 p_order_id uuid,p_courier_name text default '',p_courier_phone text default '',
 p_tracking_code text default '',p_estimated_delivery_at timestamptz default null
)
returns void
language plpgsql security definer
set search_path = public, auth
as $$
begin
 if auth.uid() is null or not exists(select 1 from public.orders where id=p_order_id and supplier_id=auth.uid()) then
  raise exception 'Заказ не найден или нет доступа';
 end if;
 if char_length(coalesce(p_courier_name,''))>120 or char_length(coalesce(p_courier_phone,''))>40 or char_length(coalesce(p_tracking_code,''))>120 then
  raise exception 'Проверьте длину данных доставки';
 end if;
 update public.orders set courier_name=coalesce(p_courier_name,''),courier_phone=coalesce(p_courier_phone,''),
  tracking_code=coalesce(p_tracking_code,''),estimated_delivery_at=p_estimated_delivery_at,updated_at=now()
 where id=p_order_id and supplier_id=auth.uid();
end;
$$;
revoke all on function public.set_supplier_delivery_details(uuid,text,text,text,timestamptz) from public,anon;
grant execute on function public.set_supplier_delivery_details(uuid,text,text,text,timestamptz) to authenticated;

-- Admin moderation: only explicit admin can suspend/reactivate a product.
create or replace function public.admin_set_product_active(p_product_id uuid,p_active boolean)
returns void
language plpgsql security definer
set search_path = public, auth
as $$
begin
 if auth.uid() is null or not public.is_kerege_admin() then raise exception 'Доступ разрешён только администратору KEREGE'; end if;
 update public.products set is_active=p_active where id=p_product_id;
 if not found then raise exception 'Товар не найден'; end if;
end;
$$;
revoke all on function public.admin_set_product_active(uuid,boolean) from public,anon;
grant execute on function public.admin_set_product_active(uuid,boolean) to authenticated;
