-- KEREGE: tighten direct update permissions
-- Run after migrations 001-004.

-- Order statuses must only be changed through the validated
-- set_supplier_request_status() SECURITY DEFINER function.
-- The app already uses this RPC, so direct table updates are unnecessary.
revoke update (status) on public.purchase_requests from authenticated;

-- Users may mark their own notifications as read, but must not be able
-- to rewrite notification content, ownership, type, or linked order.
revoke all on public.user_notifications from anon, authenticated;
grant select on public.user_notifications to authenticated;
grant update (read_at) on public.user_notifications to authenticated;

-- Reassert the row-level boundary for notification reads and read receipts.
drop policy if exists user_notifications_read_own on public.user_notifications;
create policy user_notifications_read_own
  on public.user_notifications
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists user_notifications_mark_own_read on public.user_notifications;
create policy user_notifications_mark_own_read
  on public.user_notifications
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
