create or replace function public.rupkas_register_device(
  p_account_id uuid,
  p_device_fingerprint_hash text,
  p_device_label text default null,
  p_app_version text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_user uuid := auth.uid();
  v_membership_id uuid;
  v_existing private.rupkas_device_activations%rowtype;
  v_license private.rupkas_licenses%rowtype;
  v_pro_active boolean;
  v_active_count integer;
  v_device private.rupkas_device_activations%rowtype;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if nullif(trim(p_device_fingerprint_hash), '') is null then raise exception 'DEVICE_FINGERPRINT_REQUIRED'; end if;
  if length(p_device_fingerprint_hash) > 255 then raise exception 'DEVICE_FINGERPRINT_INVALID'; end if;

  select am.id into v_membership_id
  from public.account_memberships am
  where am.account_id=p_account_id and am.user_id=v_user and am.status='active';

  if v_membership_id is null then raise exception 'ACCOUNT_MEMBERSHIP_NOT_FOUND'; end if;

  select * into v_existing
  from private.rupkas_device_activations d
  where d.account_id=p_account_id and d.device_fingerprint_hash=p_device_fingerprint_hash and d.status='ACTIVE'
  order by d.activated_at desc limit 1 for update;

  if v_existing.id is not null then
    update private.rupkas_device_activations
    set last_seen_at=now(), membership_id=v_membership_id, user_id=v_user,
        app_version=coalesce(nullif(trim(p_app_version),''),app_version),
        device_label=coalesce(nullif(trim(p_device_label),''),device_label)
    where id=v_existing.id
    returning * into v_device;

    return jsonb_build_object('status','DEVICE_ACTIVE','device_id',v_device.id,'account_id',p_account_id,'license_id',v_device.license_id);
  end if;

  select exists(
    select 1 from private.rupkas_entitlements e
    where e.account_id=p_account_id and e.plan_code='PRO_LIFETIME_RP15000'
      and e.status='ACTIVE' and (e.ends_at is null or e.ends_at>now())
  ) into v_pro_active;

  if v_pro_active then
    select * into v_license
    from private.rupkas_licenses l
    where l.account_id=p_account_id and l.plan_code='PRO_LIFETIME_RP15000' and l.status='ACTIVE'
    order by l.created_at desc limit 1 for update;

    if v_license.id is null then raise exception 'LICENSE_NOT_READY'; end if;

    select count(*) into v_active_count
    from private.rupkas_device_activations d
    where d.account_id=p_account_id and d.status='ACTIVE';

    if v_active_count >= v_license.max_active_devices then raise exception 'DEVICE_LIMIT_REACHED'; end if;
  end if;

  insert into private.rupkas_device_activations(
    account_id,membership_id,user_id,license_id,device_fingerprint_hash,device_label,app_version,status,activated_at,last_seen_at,metadata
  )
  values(
    p_account_id,v_membership_id,v_user,
    case when v_pro_active then v_license.id else null end,
    trim(p_device_fingerprint_hash),nullif(trim(p_device_label),''),nullif(trim(p_app_version),''),
    'ACTIVE',now(),now(),'{}'::jsonb
  )
  returning * into v_device;

  if v_pro_active and v_license.first_activated_at is null then
    update private.rupkas_licenses set first_activated_at=now() where id=v_license.id;
  end if;

  insert into private.rupkas_audit_events(account_id,actor_type,actor_user_id,event_type,entity_type,entity_id,metadata)
  values(p_account_id,'USER',v_user,'DEVICE_ACTIVATED','DEVICE',v_device.id,
         jsonb_build_object('app_version',p_app_version,'pro_active',v_pro_active));

  return jsonb_build_object('status','DEVICE_ACTIVE','device_id',v_device.id,'account_id',p_account_id,'license_id',v_device.license_id,'pro_active',v_pro_active);
end;
$$;

revoke all on function public.rupkas_register_device(uuid,text,text,text) from public;
grant execute on function public.rupkas_register_device(uuid,text,text,text) to authenticated;
