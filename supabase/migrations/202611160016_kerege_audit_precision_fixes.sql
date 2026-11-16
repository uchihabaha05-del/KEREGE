-- KEREGE audit fixes: consistent precision, stricter supplier operations and stock restoration.
-- Apply after migrations 001-015.

alter table public.products
  alter column min_order type numeric(14,3) using min_order::numeric(14,3);
alter table public.purchase_requests
  alter column quantity type numeric(14,3) using quantity::numeric(14,3);
alter table public.group_buys
  alter column target_qty type numeric(14,3) using target_qty::numeric(14,3),
  alter column committed_qty type numeric(14,3) using committed_qty::numeric(14,3);
alter table public.group_buy_members
  alter column quantity type numeric(14,3) using quantity::numeric(14,3);

-- Do not allow delivery metadata on pickup orders or orders outside the delivery workflow.
create or replace function public.set_supplier_delivery_details(
 p_order_id uuid,p_courier_name text default '',p_courier_phone text default '',
 p_tracking_code text default '',p_estimated_delivery_at timestamptz default null
)
returns void
language plpgsql security definer
set search_path = public, auth
as $$
declare v_order public.orders%rowtype;
begin
 if auth.uid() is null then raise exception 'Требуется авторизация'; end if;
 select * into v_order from public.orders where id=p_order_id and supplier_id=auth.uid() for update;
 if not found then raise exception 'Заказ не найден или нет доступа'; end if;
 if v_order.delivery_method <> 'supplier_delivery' then raise exception 'Данные курьера доступны только для доставки поставщиком'; end if;
 if v_order.status not in ('accepted','preparing','shipped') then raise exception 'Данные доставки можно менять только для принятых, собираемых или отправленных заказов'; end if;
 if char_length(coalesce(p_courier_name,''))>120 or char_length(coalesce(p_courier_phone,''))>40 or char_length(coalesce(p_tracking_code,''))>120 then
  raise exception 'Проверьте длину данных доставки';
 end if;
 if p_estimated_delivery_at is not null and p_estimated_delivery_at < now() - interval '1 day' then
  raise exception 'Ожидаемое время доставки не может быть в прошлом';
 end if;
 update public.orders set courier_name=coalesce(p_courier_name,''),courier_phone=coalesce(p_courier_phone,''),
  tracking_code=coalesce(p_tracking_code,''),estimated_delivery_at=p_estimated_delivery_at,updated_at=now()
 where id=p_order_id and supplier_id=auth.uid();
end;
$$;
revoke all on function public.set_supplier_delivery_details(uuid,text,text,text,timestamptz) from public,anon;
grant execute on function public.set_supplier_delivery_details(uuid,text,text,text,timestamptz) to authenticated;

-- Keep status notes bounded and never let suppliers mark receipt as completed.
create or replace function public.set_supplier_order_status(p_order_id uuid,p_new_status text,p_note text default '')
returns void
language plpgsql security definer
set search_path = public, auth
as $$
declare v_user uuid:=auth.uid(); v_order public.orders%rowtype; v_allowed boolean:=false;
begin
 if v_user is null then raise exception 'Требуется авторизация'; end if;
 if not exists(select 1 from public.profiles where id=v_user and role='supplier') then raise exception 'Доступ разрешён только поставщику'; end if;
 select * into v_order from public.orders where id=p_order_id and supplier_id=v_user for update;
 if not found then raise exception 'Заказ не найден'; end if;
 v_allowed := (v_order.status='new' and p_new_status in ('accepted','declined'))
  or (v_order.status='accepted' and p_new_status in ('preparing','ready_for_pickup','shipped'))
  or (v_order.status='preparing' and p_new_status in ('ready_for_pickup','shipped'))
  or (v_order.status='shipped' and p_new_status='delivered');
 if not v_allowed then raise exception 'Недопустимый переход статуса: % → %',v_order.status,p_new_status; end if;
 if v_order.delivery_method='pickup' and p_new_status in ('shipped','delivered') then raise exception 'Для самовывоза используйте статус «Готов к выдаче»'; end if;
 if v_order.delivery_method='supplier_delivery' and p_new_status='ready_for_pickup' then raise exception 'Для доставки используйте передачу заказа в доставку'; end if;
 update public.orders set status=p_new_status,updated_at=now(),
  accepted_at=case when p_new_status='accepted' then now() else accepted_at end,
  shipped_at=case when p_new_status='shipped' then now() else shipped_at end,
  delivered_at=case when p_new_status='delivered' then now() else delivered_at end
 where id=p_order_id;
 insert into public.order_status_events(order_id,old_status,new_status,note,changed_by)
 values(p_order_id,v_order.status,p_new_status,left(coalesce(p_note,''),500),v_user);
 update public.purchase_requests set status=case p_new_status when 'accepted' then 'accepted' when 'declined' then 'declined' else status end
 where id in (select legacy_request_id from public.order_items where order_id=p_order_id and legacy_request_id is not null)
 and p_new_status in ('accepted','declined');
end;
$$;
revoke all on function public.set_supplier_order_status(uuid,text,text) from public,anon;
grant execute on function public.set_supplier_order_status(uuid,text,text) to authenticated;

-- Ensure order cancellation is reflected in the legacy request records too.
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
 if v_order.status not in ('new','accepted') then raise exception 'Отменить можно только новый или ещё не собранный заказ'; end if;
 update public.orders set status='cancelled',updated_at=now() where id=p_order_id;
 insert into public.order_status_events(order_id,old_status,new_status,note,changed_by)
 values(p_order_id,v_order.status,'cancelled',left(coalesce(p_reason,''),500),v_user);
 update public.purchase_requests set status='cancelled'
 where id in (select legacy_request_id from public.order_items where order_id=p_order_id and legacy_request_id is not null);
end;
$$;
revoke all on function public.cancel_buyer_order(uuid,text) from public,anon;
grant execute on function public.cancel_buyer_order(uuid,text) to authenticated;
