-- Source-controlled definitions for migration 20261007095921_rupkas_control_plane_rpc_v1.
-- Generated from the deployed Supabase database after verification.

CREATE OR REPLACE FUNCTION private.reject_pro_payment(p_order_id uuid, p_admin_user_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  v_order private.rupkas_orders%rowtype;
  v_payment_id uuid;
  v_case_id uuid;
begin
  if not exists(select 1 from private.developer_admins d where d.user_id=p_admin_user_id and d.is_active=true) then
    raise exception 'DEVELOPER_ADMIN_REQUIRED';
  end if;

  select * into v_order
  from private.rupkas_orders o
  where o.id=p_order_id
  for update;

  if v_order.id is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.plan_code <> 'PRO_LIFETIME_RP15000' then raise exception 'INVALID_PRO_ORDER'; end if;
  if v_order.status in ('PAID','CANCELLED','REFUNDED') then raise exception 'ORDER_NOT_REJECTABLE'; end if;

  select p.id into v_payment_id
  from private.rupkas_payments p
  where p.order_id=p_order_id
  order by p.attempt_no desc limit 1
  for update;

  update private.rupkas_payments
  set status='REJECTED', rejected_at=now(), updated_at=now()
  where id=v_payment_id;

  update private.rupkas_orders
  set status='REJECTED', rejected_at=now(), updated_at=now()
  where id=p_order_id;

  select c.id into v_case_id
  from private.rupkas_support_cases c
  where c.order_id=p_order_id and c.status not in ('RESOLVED','CLOSED')
  order by c.created_at desc limit 1;

  if v_case_id is not null then
    update private.rupkas_support_cases
    set status='RESOLVED', resolved_at=now(), updated_at=now()
    where id=v_case_id;
    insert into private.rupkas_support_messages(case_id,sender_type,sender_user_id,body)
    values(v_case_id,'DEVELOPER',p_admin_user_id,
      'Bukti pembayaran ditolak.' || case when nullif(trim(coalesce(p_reason,'')),'') is not null then ' Alasan: '||trim(p_reason) else '' end);
  end if;

  insert into private.rupkas_audit_events(account_id,actor_type,actor_user_id,event_type,entity_type,entity_id,metadata)
  values(v_order.account_id,'DEVELOPER',p_admin_user_id,'PAYMENT_REJECTED','ORDER',p_order_id,jsonb_build_object('reason',p_reason));

  return jsonb_build_object('ok',true,'order_id',p_order_id,'status','REJECTED','case_id',v_case_id);
end;
$function$

CREATE OR REPLACE FUNCTION public.rupkas_create_pro_order(p_account_id uuid, p_payment_method text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  v_user uuid := auth.uid();
  v_role text;
  v_plan record;
  v_order private.rupkas_orders%rowtype;
  v_payment private.rupkas_payments%rowtype;
  v_case private.rupkas_support_cases%rowtype;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;

  select am.role into v_role
  from public.account_memberships am
  where am.account_id = p_account_id
    and am.user_id = v_user
    and am.status = 'active';

  if v_role is null then raise exception 'ACCOUNT_MEMBERSHIP_NOT_FOUND'; end if;
  if v_role <> 'OWNER' then raise exception 'OWNER_REQUIRED'; end if;

  if exists (
    select 1 from private.rupkas_entitlements e
    where e.account_id = p_account_id and e.plan_code = 'PRO_LIFETIME_RP15000' and e.status = 'ACTIVE'
  ) then
    raise exception 'PRO_ALREADY_ACTIVE';
  end if;

  select *
    into v_plan
  from public.rupkas_product_plans
  where code = 'PRO_LIFETIME_RP15000'
    and is_active = true
  limit 1;

  if v_plan.id is null then raise exception 'PRO_PLAN_NOT_AVAILABLE'; end if;

  select * into v_order
  from private.rupkas_orders o
  where o.account_id = p_account_id
    and o.plan_code = v_plan.code
    and o.status in ('CREATED','PAYMENT_PENDING','PAYMENT_SUBMITTED','UNDER_REVIEW')
  order by o.created_at desc
  limit 1
  for update;

  if v_order.id is not null then
    select * into v_payment
    from private.rupkas_payments p
    where p.order_id = v_order.id
    order by p.attempt_no desc
    limit 1;

    return jsonb_build_object(
      'order_id', v_order.id,
      'payment_id', v_payment.id,
      'case_id', (select c.id from private.rupkas_support_cases c where c.order_id = v_order.id order by c.created_at desc limit 1),
      'status', v_order.status,
      'amount_idr', v_order.amount_idr
    );
  end if;

  insert into private.rupkas_orders (
    account_id, plan_code, product_name_snapshot, amount_idr, currency, status, payment_method, created_at, updated_at
  )
  values (
    p_account_id, v_plan.code, v_plan.name, v_plan.price_idr, v_plan.currency, 'PAYMENT_PENDING',
    nullif(trim(p_payment_method), ''), now(), now()
  )
  returning * into v_order;

  insert into private.rupkas_payments (
    order_id, attempt_no, method, amount_idr, status, created_at, updated_at
  )
  values (
    v_order.id, 1, nullif(trim(p_payment_method), ''), v_order.amount_idr, 'PENDING', now(), now()
  )
  returning * into v_payment;

  insert into private.rupkas_support_cases (
    account_id, requester_user_id, membership_id, case_type, priority, status, order_id, created_at, updated_at
  )
  select p_account_id, v_user, am.id, 'PAYMENT', 'NORMAL', 'OPEN', v_order.id, now(), now()
  from public.account_memberships am
  where am.account_id = p_account_id and am.user_id = v_user and am.status='active'
  returning * into v_case;

  insert into private.rupkas_support_messages(case_id, sender_type, sender_user_id, body)
  values (
    v_case.id,
    'SYSTEM',
    null,
    'Order Pro dibuat. Harga Rp15.000. Kirim bukti pembayaran melalui alur pembayaran Rupkas.'
  );

  insert into private.rupkas_audit_events (
    account_id, actor_type, actor_user_id, event_type, entity_type, entity_id, metadata
  )
  values (
    p_account_id, 'USER', v_user, 'PRO_ORDER_CREATED', 'ORDER', v_order.id,
    jsonb_build_object('payment_method', p_payment_method, 'amount_idr', v_order.amount_idr)
  );

  return jsonb_build_object(
    'order_id', v_order.id,
    'payment_id', v_payment.id,
    'case_id', v_case.id,
    'status', v_order.status,
    'amount_idr', v_order.amount_idr
  );
end;
$function$

CREATE OR REPLACE FUNCTION public.rupkas_developer_confirm_pro_payment(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from private.developer_admins d where d.user_id=v_user and d.is_active=true) then
    raise exception 'DEVELOPER_ADMIN_REQUIRED';
  end if;
  return private.confirm_pro_payment(p_order_id,v_user);
end;
$function$

CREATE OR REPLACE FUNCTION public.rupkas_developer_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  v_user uuid := auth.uid();
  v_orders jsonb;
  v_cases jsonb;
  v_accounts jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from private.developer_admins d where d.user_id=v_user and d.is_active=true) then
    raise exception 'DEVELOPER_ADMIN_REQUIRED';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb)
  into v_accounts
  from (
    select a.id,a.public_account_id,a.name,a.status,a.created_at,
           ca.lifecycle_status,
           t.status as trial_status,t.expires_at,
           exists(select 1 from private.rupkas_entitlements e where e.account_id=a.id and e.plan_code='PRO_LIFETIME_RP15000' and e.status='ACTIVE') as pro_active
    from public.accounts a
    join private.rupkas_commercial_accounts ca on ca.account_id=a.id
    join private.rupkas_trial_lifecycle t on t.account_id=a.id
    order by a.created_at desc
    limit 200
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb)
  into v_orders
  from (
    select o.id,o.account_id,a.public_account_id,a.name as account_name,o.plan_code,o.product_name_snapshot,
           o.amount_idr,o.status,o.payment_method,o.created_at,o.submitted_at,o.paid_at,
           p.status as payment_status,p.verified_at,p.verified_by
    from private.rupkas_orders o
    join public.accounts a on a.id=o.account_id
    left join lateral (
      select p.* from private.rupkas_payments p where p.order_id=o.id order by p.attempt_no desc limit 1
    ) p on true
    order by o.created_at desc
    limit 200
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb)
  into v_cases
  from (
    select c.id,c.account_id,a.public_account_id,a.name as account_name,c.case_type,c.priority,c.status,c.order_id,c.created_at,c.updated_at,
           c.assigned_admin_id
    from private.rupkas_support_cases c
    join public.accounts a on a.id=c.account_id
    where c.status not in ('RESOLVED','CLOSED')
    order by c.created_at desc
    limit 200
  ) x;

  return jsonb_build_object(
    'generated_at',now(),
    'counts',jsonb_build_object(
      'accounts',(select count(*) from public.accounts where status='active'),
      'trial_active',(select count(*) from private.rupkas_trial_lifecycle where status='ACTIVE'),
      'recovery',(select count(*) from private.rupkas_trial_lifecycle where status='RECOVERY'),
      'deletion_pending',(select count(*) from private.rupkas_data_lifecycle where state='DELETION_PENDING'),
      'orders_open',(select count(*) from private.rupkas_orders where status in ('PAYMENT_PENDING','PAYMENT_SUBMITTED','UNDER_REVIEW')),
      'support_open',(select count(*) from private.rupkas_support_cases where status not in ('RESOLVED','CLOSED'))
    ),
    'accounts',v_accounts,
    'orders',v_orders,
    'support',v_cases
  );
end;
$function$

CREATE OR REPLACE FUNCTION public.rupkas_developer_reject_pro_payment(p_order_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from private.developer_admins d where d.user_id=auth.uid() and d.is_active=true) then raise exception 'DEVELOPER_ADMIN_REQUIRED'; end if;
  return private.reject_pro_payment(p_order_id,auth.uid(),p_reason);
end;
$function$

CREATE OR REPLACE FUNCTION public.rupkas_developer_reply_support_case(p_case_id uuid, p_body text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare v_user uuid := auth.uid(); v_account uuid;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from private.developer_admins d where d.user_id=v_user and d.is_active=true) then raise exception 'DEVELOPER_ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_body,''))) < 1 or char_length(p_body) > 10000 then raise exception 'INVALID_MESSAGE'; end if;

  select account_id into v_account from private.rupkas_support_cases where id=p_case_id for update;
  if v_account is null then raise exception 'SUPPORT_CASE_NOT_FOUND'; end if;

  insert into private.rupkas_support_messages(case_id,sender_type,sender_user_id,body)
  values(p_case_id,'DEVELOPER',v_user,trim(p_body));

  update private.rupkas_support_cases
  set assigned_admin_id=v_user, status='WAITING_USER', updated_at=now()
  where id=p_case_id;

  return jsonb_build_object('ok',true,'case_id',p_case_id);
end;
$function$

CREATE OR REPLACE FUNCTION public.rupkas_get_commercial_state(p_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  v_user uuid := auth.uid();
  v_account uuid;
  v_role text;
  v_sub_id text;
  v_result jsonb;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select am.account_id, am.role, am.sub_rupkas_id
    into v_account, v_role, v_sub_id
  from public.account_memberships am
  where am.user_id = v_user
    and am.status = 'active'
    and (p_account_id is null or am.account_id = p_account_id)
  order by case when am.account_id = p_account_id then 0 else 1 end, am.joined_at
  limit 1;

  if v_account is null then
    raise exception 'ACCOUNT_MEMBERSHIP_NOT_FOUND';
  end if;

  with latest_entitlement as (
    select e.*
    from private.rupkas_entitlements e
    where e.account_id = v_account
      and e.status = 'ACTIVE'
    order by e.starts_at desc, e.created_at desc
    limit 1
  ),
  latest_license as (
    select l.*
    from private.rupkas_licenses l
    where l.account_id = v_account
      and l.status in ('ACTIVE','PENDING')
    order by l.created_at desc
    limit 1
  ),
  latest_order as (
    select o.*
    from private.rupkas_orders o
    where o.account_id = v_account
    order by o.created_at desc
    limit 1
  )
  select jsonb_build_object(
    'account', jsonb_build_object(
      'id', a.id,
      'public_account_id', a.public_account_id,
      'name', a.name,
      'status', a.status,
      'member_limit', a.member_limit
    ),
    'membership', jsonb_build_object(
      'role', v_role,
      'sub_rupkas_id', v_sub_id
    ),
    'email', (select u.email from auth.users u where u.id = v_user),
    'commercial', jsonb_build_object(
      'lifecycle_status', ca.lifecycle_status,
      'first_activation_at', ca.first_activation_at
    ),
    'trial', jsonb_build_object(
      'status', t.status,
      'started_at', t.started_at,
      'expires_at', t.expires_at,
      'recovery_started_at', t.recovery_started_at,
      'recovery_expires_at', t.recovery_expires_at
    ),
    'entitlement', case when le.id is null then null else jsonb_build_object(
      'id', le.id,
      'plan_code', le.plan_code,
      'source_type', le.source_type,
      'status', le.status,
      'starts_at', le.starts_at,
      'ends_at', le.ends_at
    ) end,
    'license', case when ll.id is null then null else jsonb_build_object(
      'id', ll.id,
      'plan_code', ll.plan_code,
      'status', ll.status,
      'lifetime', ll.lifetime,
      'max_active_devices', ll.max_active_devices,
      'first_activated_at', ll.first_activated_at
    ) end,
    'latest_order', case when lo.id is null then null else jsonb_build_object(
      'id', lo.id,
      'plan_code', lo.plan_code,
      'product_name', lo.product_name_snapshot,
      'amount_idr', lo.amount_idr,
      'status', lo.status,
      'payment_method', lo.payment_method,
      'created_at', lo.created_at,
      'submitted_at', lo.submitted_at,
      'paid_at', lo.paid_at
    ) end
  )
  into v_result
  from public.accounts a
  join private.rupkas_commercial_accounts ca on ca.account_id = a.id
  join private.rupkas_trial_lifecycle t on t.account_id = a.id
  left join latest_entitlement le on true
  left join latest_license ll on true
  left join latest_order lo on true
  where a.id = v_account;

  return v_result;
end;
$function$

CREATE OR REPLACE FUNCTION public.rupkas_get_support_case(p_case_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  v_user uuid := auth.uid();
  v_account uuid;
  v_case jsonb;
  v_messages jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;

  select c.account_id into v_account
  from private.rupkas_support_cases c
  where c.id=p_case_id
    and exists (
      select 1 from public.account_memberships am
      where am.account_id=c.account_id and am.user_id=v_user and am.status='active'
    );

  if v_account is null then raise exception 'SUPPORT_CASE_NOT_FOUND'; end if;

  select to_jsonb(c) into v_case from private.rupkas_support_cases c where c.id=p_case_id;
  select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at),'[]'::jsonb)
    into v_messages
  from private.rupkas_support_messages m
  where m.case_id=p_case_id;

  return jsonb_build_object('case',v_case,'messages',v_messages);
end;
$function$

CREATE OR REPLACE FUNCTION public.rupkas_list_support_cases()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  v_user uuid := auth.uid();
  v_rows jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb)
    into v_rows
  from (
    select c.id, c.account_id, c.case_type, c.priority, c.status, c.order_id, c.created_at, c.updated_at,
           (select count(*) from private.rupkas_support_messages m where m.case_id=c.id) as message_count
    from private.rupkas_support_cases c
    where exists (
      select 1 from public.account_memberships am
      where am.account_id=c.account_id and am.user_id=v_user and am.status='active'
    )
  ) x;

  return v_rows;
end;
$function$

CREATE OR REPLACE FUNCTION public.rupkas_reply_support_case(p_case_id uuid, p_body text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  v_user uuid := auth.uid();
  v_account uuid;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if char_length(trim(coalesce(p_body,''))) < 1 or char_length(p_body) > 10000 then raise exception 'INVALID_MESSAGE'; end if;

  select c.account_id into v_account
  from private.rupkas_support_cases c
  where c.id=p_case_id
    and exists (
      select 1 from public.account_memberships am
      where am.account_id=c.account_id and am.user_id=v_user and am.status='active'
    );

  if v_account is null then raise exception 'SUPPORT_CASE_NOT_FOUND'; end if;

  insert into private.rupkas_support_messages(case_id,sender_type,sender_user_id,body)
  values(p_case_id,'USER',v_user,trim(p_body));

  update private.rupkas_support_cases
  set status=case when status in ('OPEN','WAITING_USER') then 'UNDER_REVIEW' else status end,
      updated_at=now()
  where id=p_case_id;

  return jsonb_build_object('ok',true,'case_id',p_case_id);
end;
$function$

CREATE OR REPLACE FUNCTION public.rupkas_start_trial(p_account_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  v_user uuid := auth.uid();
  v_role text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;

  select am.role into v_role
  from public.account_memberships am
  where am.account_id = p_account_id
    and am.user_id = v_user
    and am.status = 'active';

  if v_role is null then raise exception 'ACCOUNT_MEMBERSHIP_NOT_FOUND'; end if;
  if v_role <> 'OWNER' then raise exception 'OWNER_REQUIRED'; end if;

  return private.start_account_activation(p_account_id, v_user);
end;
$function$

CREATE OR REPLACE FUNCTION public.rupkas_submit_payment_proof_metadata(p_order_id uuid, p_storage_bucket text, p_storage_path text, p_mime_type text, p_size_bytes bigint, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  v_user uuid := auth.uid();
  v_order private.rupkas_orders%rowtype;
  v_payment private.rupkas_payments%rowtype;
  v_proof private.rupkas_payment_proofs%rowtype;
  v_case_id uuid;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;

  select o.* into v_order
  from private.rupkas_orders o
  join public.account_memberships am on am.account_id = o.account_id
  where o.id = p_order_id
    and am.user_id = v_user
    and am.status = 'active'
    and am.role = 'OWNER'
  for update of o;

  if v_order.id is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.plan_code <> 'PRO_LIFETIME_RP15000' then raise exception 'INVALID_PRO_ORDER'; end if;
  if v_order.status not in ('PAYMENT_PENDING','CREATED','PAYMENT_SUBMITTED','UNDER_REVIEW') then raise exception 'ORDER_NOT_ACCEPTING_PROOF'; end if;
  if p_size_bytes <= 0 or p_size_bytes > 5242880 then raise exception 'PROOF_TOO_LARGE'; end if;
  if p_mime_type not in ('image/jpeg','image/png','image/webp','application/pdf') then raise exception 'PROOF_MIME_NOT_ALLOWED'; end if;

  select p.* into v_payment
  from private.rupkas_payments p
  where p.order_id = v_order.id
  order by p.attempt_no desc
  limit 1
  for update;

  if v_payment.id is null then raise exception 'PAYMENT_NOT_FOUND'; end if;

  insert into private.rupkas_payment_proofs (
    payment_id, storage_bucket, storage_path, mime_type, size_bytes, sha256, status, uploaded_at, expires_at
  )
  values (
    v_payment.id, p_storage_bucket, p_storage_path, p_mime_type, p_size_bytes, p_sha256,
    'ACTIVE', now(), now() + interval '5 hours'
  )
  returning * into v_proof;

  update private.rupkas_payments
  set status='PROOF_SUBMITTED', submitted_at=coalesce(submitted_at,now()), under_review_started_at=now(), updated_at=now()
  where id=v_payment.id;

  update private.rupkas_orders
  set status='PAYMENT_SUBMITTED', submitted_at=coalesce(submitted_at,now()), updated_at=now()
  where id=v_order.id;

  select c.id into v_case_id
  from private.rupkas_support_cases c
  where c.order_id=v_order.id
    and c.case_type='PAYMENT'
    and c.status not in ('RESOLVED','CLOSED')
  order by c.created_at desc
  limit 1;

  if v_case_id is not null then
    update private.rupkas_support_cases set status='UNDER_REVIEW', updated_at=now() where id=v_case_id;
    insert into private.rupkas_support_messages(case_id, sender_type, sender_user_id, body)
    values (v_case_id,'USER',v_user,'Bukti pembayaran telah dikirim untuk ditinjau.');
  end if;

  insert into private.rupkas_audit_events (
    account_id, actor_type, actor_user_id, event_type, entity_type, entity_id, metadata
  )
  values (
    v_order.account_id, 'USER', v_user, 'PAYMENT_PROOF_SUBMITTED', 'PAYMENT_PROOF', v_proof.id,
    jsonb_build_object('order_id',v_order.id,'payment_id',v_payment.id,'size_bytes',p_size_bytes,'mime_type',p_mime_type)
  );

  return jsonb_build_object('proof_id',v_proof.id,'order_id',v_order.id,'payment_id',v_payment.id,'case_id',v_case_id,'status','UNDER_REVIEW');
end;
$function$

revoke all on function public.rupkas_get_commercial_state(uuid) from public; grant execute on function public.rupkas_get_commercial_state(uuid) to authenticated;
revoke all on function public.rupkas_start_trial(uuid) from public; grant execute on function public.rupkas_start_trial(uuid) to authenticated;
revoke all on function public.rupkas_create_pro_order(uuid,text) from public; grant execute on function public.rupkas_create_pro_order(uuid,text) to authenticated;
revoke all on function public.rupkas_submit_payment_proof_metadata(uuid,text,text,text,bigint,text) from public; grant execute on function public.rupkas_submit_payment_proof_metadata(uuid,text,text,text,bigint,text) to authenticated;
revoke all on function public.rupkas_list_support_cases() from public; grant execute on function public.rupkas_list_support_cases() to authenticated;
revoke all on function public.rupkas_get_support_case(uuid) from public; grant execute on function public.rupkas_get_support_case(uuid) to authenticated;
revoke all on function public.rupkas_reply_support_case(uuid,text) from public; grant execute on function public.rupkas_reply_support_case(uuid,text) to authenticated;
revoke all on function public.rupkas_developer_overview() from public; grant execute on function public.rupkas_developer_overview() to authenticated;
revoke all on function public.rupkas_developer_confirm_pro_payment(uuid) from public; grant execute on function public.rupkas_developer_confirm_pro_payment(uuid) to authenticated;
revoke all on function public.rupkas_developer_reject_pro_payment(uuid,text) from public; grant execute on function public.rupkas_developer_reject_pro_payment(uuid,text) to authenticated;
revoke all on function public.rupkas_developer_reply_support_case(uuid,text) from public; grant execute on function public.rupkas_developer_reply_support_case(uuid,text) to authenticated;
revoke all on function private.reject_pro_payment(uuid,uuid,text) from public,anon,authenticated;
