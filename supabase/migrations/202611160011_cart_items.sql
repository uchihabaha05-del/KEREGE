-- KEREGE: persistent buyer cart
create table if not exists public.cart_items (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null references auth.users(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  quantity numeric(14,3) not null check (quantity > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (buyer_id, product_id)
);
alter table public.cart_items enable row level security;
drop policy if exists cart_items_select_own on public.cart_items;
create policy cart_items_select_own on public.cart_items for select to authenticated using (buyer_id = auth.uid());
drop policy if exists cart_items_insert_own on public.cart_items;
create policy cart_items_insert_own on public.cart_items for insert to authenticated with check (buyer_id = auth.uid());
drop policy if exists cart_items_update_own on public.cart_items;
create policy cart_items_update_own on public.cart_items for update to authenticated using (buyer_id = auth.uid()) with check (buyer_id = auth.uid());
drop policy if exists cart_items_delete_own on public.cart_items;
create policy cart_items_delete_own on public.cart_items for delete to authenticated using (buyer_id = auth.uid());
create index if not exists cart_items_buyer_created_idx on public.cart_items(buyer_id, created_at desc);
grant select, insert, update, delete on public.cart_items to authenticated;
