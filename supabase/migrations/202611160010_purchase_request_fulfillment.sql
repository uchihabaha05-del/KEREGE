-- KEREGE: buyer-selected fulfillment method for purchase requests
alter table public.purchase_requests
  add column if not exists delivery_method text,
  add column if not exists delivery_details text not null default '';
alter table public.purchase_requests drop constraint if exists purchase_requests_delivery_method_check;
alter table public.purchase_requests add constraint purchase_requests_delivery_method_check
  check (delivery_method is null or delivery_method in ('supplier_delivery','pickup'));
