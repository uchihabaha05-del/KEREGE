-- KEREGE: supplier order management
-- Run after 202611160001_init.sql.

create or replace function public.get_supplier_purchase_requests()
returns table (
  request_id uuid,
  buyer_name text,
  buyer_phone text,
  product_name text,
  quantity numeric,
  unit text,
  unit_price numeric,
  message text,
  request_status text,
  requested_at timestamptz
)
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'Требуется авторизация';
  end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = v_user and p.role = 'supplier'
  ) then
    raise exception 'Доступ разрешён только поставщику';
  end if;

  return query
  select
    r.id,
    coalesce(b.full_name, 'Покупатель'),
    coalesce(b.phone, ''),
    pr.name,
    r.quantity,
    pr.unit,
    pr.price,
    r.message,
    r.status,
    r.created_at
  from public.purchase_requests r
  join public.profiles b on b.id = r.buyer_id
  join public.products pr on pr.id = r.product_id
  where r.supplier_id = v_user
  order by r.created_at desc;
end;
$$;

create or replace function public.set_supplier_request_status(
  p_request_id uuid,
  p_new_status text
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_old_status text;
begin
  if v_user is null then
    raise exception 'Требуется авторизация';
  end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = v_user and p.role = 'supplier'
  ) then
    raise exception 'Доступ разрешён только поставщику';
  end if;
  if p_new_status not in ('accepted', 'declined', 'completed') then
    raise exception 'Недопустимый статус заявки';
  end if;

  select r.status into v_old_status
  from public.purchase_requests r
  where r.id = p_request_id and r.supplier_id = v_user
  for update;

  if not found then
    raise exception 'Заявка не найдена';
  end if;

  if v_old_status = 'new' and p_new_status in ('accepted', 'declined') then
    update public.purchase_requests
      set status = p_new_status
      where id = p_request_id and supplier_id = v_user;
  elsif v_old_status = 'accepted' and p_new_status = 'completed' then
    update public.purchase_requests
      set status = p_new_status
      where id = p_request_id and supplier_id = v_user;
  else
    raise exception 'Нельзя изменить статус с % на %', v_old_status, p_new_status;
  end if;
end;
$$;

revoke all on function public.get_supplier_purchase_requests() from public, anon;
revoke all on function public.set_supplier_request_status(uuid, text) from public, anon;
grant execute on function public.get_supplier_purchase_requests() to authenticated;
grant execute on function public.set_supplier_request_status(uuid, text) to authenticated;
