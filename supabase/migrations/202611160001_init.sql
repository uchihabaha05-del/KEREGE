-- KEREGE initial schema migration
-- Run once in Supabase SQL Editor. Client uses publishable key + RLS.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  email text,
  phone text,
  role text not null check (role in ('buyer','supplier')),
  city text not null default 'Бишкек',
  created_at timestamptz not null default now()
);

create table if not exists public.supplier_public_profiles (
  id uuid primary key references public.profiles(id) on delete cascade,
  display_name text not null default 'Поставщик',
  city text not null default 'Бишкек'
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles(id,full_name,email,phone,role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name',''),
    new.email,
    coalesce(new.raw_user_meta_data->>'phone',''),
    case when new.raw_user_meta_data->>'role'='supplier' then 'supplier' else 'buyer' end
  );
  if coalesce(new.raw_user_meta_data->>'role','buyer')='supplier' then
    insert into public.supplier_public_profiles(id,display_name,city)
    values(new.id,coalesce(nullif(new.raw_user_meta_data->>'full_name',''),'Поставщик'),'Бишкек');
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_kerege on auth.users;
create trigger on_auth_user_created_kerege after insert on auth.users
for each row execute procedure public.handle_new_user();

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.supplier_public_profiles(id) on delete cascade,
  name text not null,
  category text not null default 'Другое',
  price numeric(12,2) not null check(price>0),
  unit text not null,
  min_order numeric(12,2) not null default 1 check(min_order>0),
  city text not null default 'Бишкек',
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.purchase_requests (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null references public.profiles(id) on delete cascade,
  supplier_id uuid not null references public.supplier_public_profiles(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(12,2) not null check(quantity>0),
  message text not null default '',
  status text not null default 'new' check(status in ('new','accepted','declined','completed','cancelled')),
  created_at timestamptz not null default now(),
  check(buyer_id <> supplier_id)
);

create table if not exists public.group_buys (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.supplier_public_profiles(id) on delete cascade,
  title text not null,
  unit text not null,
  price numeric(12,2) not null check(price>0),
  target_qty numeric(12,2) not null check(target_qty>0),
  committed_qty numeric(12,2) not null default 0 check(committed_qty>=0),
  city text not null default 'Бишкек',
  ends_at timestamptz not null,
  status text not null default 'open' check(status in ('open','target_reached','closed','cancelled')),
  created_at timestamptz not null default now()
);

create table if not exists public.group_buy_members (
  id uuid primary key default gen_random_uuid(),
  group_buy_id uuid not null references public.group_buys(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  quantity numeric(12,2) not null check(quantity>0),
  status text not null default 'interested' check(status in ('interested','confirmed','withdrawn')),
  created_at timestamptz not null default now(),
  unique(group_buy_id,user_id)
);

create index if not exists products_active_created_idx on public.products(is_active,created_at desc);
create index if not exists requests_buyer_created_idx on public.purchase_requests(buyer_id,created_at desc);
create index if not exists requests_supplier_created_idx on public.purchase_requests(supplier_id,created_at desc);
create index if not exists groups_status_ends_idx on public.group_buys(status,ends_at);
create index if not exists group_members_user_idx on public.group_buy_members(user_id,created_at desc);

-- Atomic group-buy join. It prevents oversubscription under concurrent requests.
create or replace function public.join_group_buy(p_group_buy_id uuid,p_quantity numeric)
returns uuid language plpgsql security definer set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_group public.group_buys%rowtype;
  v_member uuid;
  v_old numeric := 0;
  v_total numeric;
begin
  if v_user is null then raise exception 'Требуется авторизация'; end if;
  if p_quantity is null or p_quantity<=0 then raise exception 'Количество должно быть больше нуля'; end if;
  if not exists(select 1 from public.profiles where id=v_user and role='buyer') then
    raise exception 'Участвовать могут только покупатели';
  end if;
  select * into v_group from public.group_buys where id=p_group_buy_id for update;
  if not found then raise exception 'Закупка не найдена'; end if;
  if v_group.status<>'open' or v_group.ends_at<=now() then raise exception 'Закупка закрыта'; end if;
  select id,quantity into v_member,v_old from public.group_buy_members
    where group_buy_id=p_group_buy_id and user_id=v_user and status<>'withdrawn' for update;
  v_total:=v_group.committed_qty-coalesce(v_old,0)+p_quantity;
  if v_total>v_group.target_qty then raise exception 'Недостаточно свободного объёма'; end if;
  if v_member is null then
    insert into public.group_buy_members(group_buy_id,user_id,quantity)
    values(p_group_buy_id,v_user,p_quantity) returning id into v_member;
  else
    update public.group_buy_members set quantity=p_quantity,status='interested' where id=v_member;
  end if;
  update public.group_buys set committed_qty=v_total,
    status=case when v_total>=target_qty then 'target_reached' else 'open' end
    where id=p_group_buy_id;
  return v_member;
end;
$$;

alter table public.profiles enable row level security;
alter table public.supplier_public_profiles enable row level security;
alter table public.products enable row level security;
alter table public.purchase_requests enable row level security;
alter table public.group_buys enable row level security;
alter table public.group_buy_members enable row level security;

-- Explicit least-privilege grants.
revoke all on public.profiles,public.supplier_public_profiles,public.products,public.purchase_requests,public.group_buys,public.group_buy_members from anon,authenticated;
grant select on public.supplier_public_profiles,public.products,public.group_buys to anon,authenticated;
grant select on public.profiles,public.purchase_requests,public.group_buy_members to authenticated;
grant insert (supplier_id,name,category,price,unit,min_order,city) on public.products to authenticated;
grant update (name,category,price,unit,min_order,city,is_active) on public.products to authenticated;
grant delete on public.products to authenticated;

grant insert (supplier_id,title,unit,price,target_qty,city,ends_at) on public.group_buys to authenticated;
grant update (title,unit,price,target_qty,city,ends_at,status) on public.group_buys to authenticated;
grant delete on public.group_buys to authenticated;

grant insert (buyer_id,supplier_id,product_id,quantity,message) on public.purchase_requests to authenticated;
grant update(status) on public.purchase_requests to authenticated;
grant execute on function public.join_group_buy(uuid,numeric) to authenticated;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated using(id=auth.uid());

drop policy if exists supplier_public_read on public.supplier_public_profiles;
create policy supplier_public_read on public.supplier_public_profiles for select to anon,authenticated using(true);

drop policy if exists products_public_read on public.products;
create policy products_public_read on public.products for select to anon,authenticated using(is_active=true or supplier_id=auth.uid());
drop policy if exists products_supplier_insert on public.products;
create policy products_supplier_insert on public.products for insert to authenticated
with check(supplier_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='supplier'));
drop policy if exists products_supplier_update on public.products;
create policy products_supplier_update on public.products for update to authenticated using(supplier_id=auth.uid()) with check(supplier_id=auth.uid());
drop policy if exists products_supplier_delete on public.products;
create policy products_supplier_delete on public.products for delete to authenticated using(supplier_id=auth.uid());

drop policy if exists requests_parties_read on public.purchase_requests;
create policy requests_parties_read on public.purchase_requests for select to authenticated using(buyer_id=auth.uid() or supplier_id=auth.uid());
drop policy if exists buyer_request_insert on public.purchase_requests;
create policy buyer_request_insert on public.purchase_requests for insert to authenticated with check(
  buyer_id=auth.uid()
  and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='buyer')
  and exists(select 1 from public.products pr where pr.id=product_id and pr.supplier_id=supplier_id and pr.is_active=true)
);
drop policy if exists supplier_request_status_update on public.purchase_requests;
create policy supplier_request_status_update on public.purchase_requests for update to authenticated
using(supplier_id=auth.uid()) with check(supplier_id=auth.uid());

drop policy if exists groups_public_read on public.group_buys;
create policy groups_public_read on public.group_buys for select to anon,authenticated using(status in ('open','target_reached') or supplier_id=auth.uid());
drop policy if exists supplier_group_insert on public.group_buys;
create policy supplier_group_insert on public.group_buys for insert to authenticated
with check(supplier_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='supplier'));
drop policy if exists supplier_group_update on public.group_buys;
create policy supplier_group_update on public.group_buys for update to authenticated using(supplier_id=auth.uid()) with check(supplier_id=auth.uid());
drop policy if exists supplier_group_delete on public.group_buys;
create policy supplier_group_delete on public.group_buys for delete to authenticated using(supplier_id=auth.uid());

drop policy if exists group_members_read_own_or_supplier on public.group_buy_members;
create policy group_members_read_own_or_supplier on public.group_buy_members for select to authenticated
using(user_id=auth.uid() or exists(select 1 from public.group_buys g where g.id=group_buy_id and g.supplier_id=auth.uid()));

revoke insert,update,delete on public.group_buy_members from anon,authenticated;
