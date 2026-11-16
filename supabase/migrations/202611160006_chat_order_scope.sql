-- KEREGE: bind chat row access to the order participants
-- Run after migrations 001-005.

drop policy if exists order_messages_parties_read on public.order_messages;
create policy order_messages_parties_read
  on public.order_messages
  for select to authenticated
  using (
    exists (
      select 1
      from public.purchase_requests r
      where r.id = request_id
        and (r.buyer_id = auth.uid() or r.supplier_id = auth.uid())
        and (sender_id = auth.uid() or recipient_id = auth.uid())
    )
  );

drop policy if exists order_messages_recipient_mark_read on public.order_messages;
create policy order_messages_recipient_mark_read
  on public.order_messages
  for update to authenticated
  using (
    recipient_id = auth.uid()
    and exists (
      select 1
      from public.purchase_requests r
      where r.id = request_id
        and (r.buyer_id = auth.uid() or r.supplier_id = auth.uid())
    )
  )
  with check (
    recipient_id = auth.uid()
    and exists (
      select 1
      from public.purchase_requests r
      where r.id = request_id
        and (r.buyer_id = auth.uid() or r.supplier_id = auth.uid())
    )
  );
