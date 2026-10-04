-- Rupkas security hardening: shrink the RPC attack surface, pin SECURITY DEFINER
-- search_path, and require verified accounts for auxiliary write surfaces.

alter function private.handle_verified_user() set search_path = '';
alter function private.provision_verified_user() set search_path = '';
alter function private.is_member(uuid) set search_path = '';
alter function private.is_owner(uuid) set search_path = '';
alter function private.verified() set search_path = '';
alter function public.create_family_space(text) set search_path = '';
alter function public.create_invitation(uuid,text,integer) set search_path = '';
alter function public.create_invitation(uuid,integer) set search_path = '';
alter function public.claim_invitation(text) set search_path = '';

alter policy p_revision_insert
  on public.entity_revisions
  with check (private.verified() and private.is_member(space_id) and changed_by=(select auth.uid()));
alter policy p_revision_member
  on public.entity_revisions
  using (private.verified() and private.is_member(space_id));

alter policy p_sync_insert
  on public.sync_operations
  with check (private.verified() and user_id=(select auth.uid()));
alter policy p_sync_self
  on public.sync_operations
  using (private.verified() and user_id=(select auth.uid()));
alter policy p_sync_update
  on public.sync_operations
  using (private.verified() and user_id=(select auth.uid()))
  with check (private.verified() and user_id=(select auth.uid()));

alter policy p_notification_manage
  on public.notification_preferences
  using (private.verified() and (select auth.uid())=user_id)
  with check (private.verified() and (select auth.uid())=user_id);

alter policy p_profile_select
  on public.profiles
  using (private.verified() and (select auth.uid())=id);
alter policy p_profile_update
  on public.profiles
  using (private.verified() and (select auth.uid())=id)
  with check (private.verified() and (select auth.uid())=id);

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon;

grant execute on function public.add_savings_movement(uuid,text,numeric,date,uuid) to authenticated;
grant execute on function public.claim_invitation(text) to authenticated;
grant execute on function public.create_bill(uuid,text,numeric,integer,uuid,text) to authenticated;
grant execute on function public.create_debt(uuid,text,text,text,numeric,date,text) to authenticated;
grant execute on function public.create_family_space(text) to authenticated;
grant execute on function public.create_fixed_bill(uuid,text,numeric,text,date,integer) to authenticated;
grant execute on function public.create_invitation(uuid,text,integer) to authenticated;
revoke execute on function public.create_invitation(uuid,integer) from authenticated;
grant execute on function public.create_savings_goal(uuid,text,numeric,date) to authenticated;
grant execute on function public.create_transaction(uuid,tx_type,numeric,uuid,date,time without time zone,text,text,uuid) to authenticated;
grant execute on function public.ensure_bill_occurrence(uuid,text,date,numeric) to authenticated;
grant execute on function public.get_month_summary(uuid,date) to authenticated;
grant execute on function public.list_savings_goals(uuid) to authenticated;
grant execute on function public.record_bill_payment(uuid,numeric,date) to authenticated;
grant execute on function public.record_debt_payment(uuid,numeric,date,uuid) to authenticated;
grant execute on function public.settle_debt(uuid) to authenticated;
grant execute on function public.sync_transaction_update(uuid,uuid,integer,tx_type,numeric,uuid,date,time without time zone,text) to authenticated;
grant execute on function public.update_family_space_name(uuid,text) to authenticated;
grant execute on function public.update_transaction(uuid,integer,tx_type,numeric,uuid,date,time without time zone,text) to authenticated;
grant execute on function public.upsert_budget(uuid,date,date,numeric,numeric) to authenticated;
grant execute on function public.void_transaction(uuid,integer,text) to authenticated;

grant execute on function private.is_member(uuid) to authenticated;
grant execute on function private.is_owner(uuid) to authenticated;
grant execute on function private.verified() to authenticated;

alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema private revoke execute on functions from public, anon, authenticated;
