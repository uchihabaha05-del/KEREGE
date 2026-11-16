-- KEREGE: public supplier company profiles
alter table public.supplier_public_profiles
  add column if not exists description text not null default '',
  add column if not exists phone text not null default '',
  add column if not exists whatsapp text not null default '',
  add column if not exists website text not null default '',
  add column if not exists address text not null default '',
  add column if not exists logo_url text not null default '',
  add column if not exists updated_at timestamptz not null default now();

grant update (display_name,city,description,phone,whatsapp,website,address,logo_url,updated_at)
  on public.supplier_public_profiles to authenticated;

drop policy if exists supplier_profile_update_own on public.supplier_public_profiles;
create policy supplier_profile_update_own
  on public.supplier_public_profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

create index if not exists products_supplier_active_created_idx
  on public.products(supplier_id,is_active,created_at desc);
