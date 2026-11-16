-- KEREGE: allow buyers to include fulfillment fields when creating purchase requests.
-- The initial security migration granted INSERT only on the original request columns.
-- The app now supplies delivery_method and delivery_details as part of each request.
grant insert (delivery_method, delivery_details)
  on public.purchase_requests to authenticated;
