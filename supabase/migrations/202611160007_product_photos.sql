-- KEREGE: product photos
-- Run after migrations 001-006.
alter table public.products
  add column if not exists image_url text;

alter table public.products
  drop constraint if exists products_image_url_http_check;

alter table public.products
  add constraint products_image_url_http_check
  check (image_url is null or image_url ~* '^https?://');
  
grant insert (supplier_id,name,category,price,unit,min_order,city,image_url)
  on public.products to authenticated;
grant update (name,category,price,unit,min_order,city,is_active,image_url)
  on public.products to authenticated;
