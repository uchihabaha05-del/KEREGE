-- KEREGE: persistent buyer favorites
-- Run after migrations 001-007.

create table if not exists public.product_favorites (
  user_id uuid not null references public.profiles(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, product_id)
);

create index if not exists product_favorites_product_idx
  on public.product_favorites(product_id);

alter table public.product_favorites enable row level security;
revoke all on public.product_favorites from anon, authenticated;
grant select, insert, delete on public.product_favorites to authenticated;

drop policy if exists product_favorites_read_own on public.product_favorites;
create policy product_favorites_read_own
  on public.product_favorites
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists product_favorites_insert_own on public.product_favorites;
create policy product_favorites_insert_own
  on public.product_favorites
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.products p
      where p.id = product_id and p.is_active = true
    )
  );

drop policy if exists product_favorites_delete_own on public.product_favorites;
create policy product_favorites_delete_own
  on public.product_favorites
  for delete to authenticated
  using (user_id = auth.uid());
