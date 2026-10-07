-- Applied in Supabase as rupkas_rkp_restore_v1.
-- Source-controlled migration anchor.

create or replace function public.rupkas_restore_rkp_payload(
  p_target_space_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user uuid := auth.uid();
  v_account_id uuid;
  v_account_public_id text;
  v_profile_rupkas_id text;
  v_space_owner uuid;
  v_space_type text;
  v_existing_count bigint;
  v_cat_map jsonb := '{}'::jsonb;
  v_goal_map jsonb := '{}'::jsonb;
  r jsonb;
  v_id uuid;
  v_goal_id uuid;
  v_parent_id uuid;
  v_category_key text;
  v_count_categories integer := 0;
  v_count_transactions integer := 0;
  v_count_debts integer := 0;
  v_count_goals integer := 0;
  v_count_movements integer := 0;
  v_count_bills integer := 0;
  v_count_budgets integer := 0;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_payload->>'format' <> 'RKP' or (p_payload->>'version')::int <> 1 then raise exception 'RKP_UNSUPPORTED_FORMAT'; end if;

  select s.account_id, s.owner_user_id, s.type::text
    into v_account_id, v_space_owner, v_space_type
  from public.spaces s where s.id=p_target_space_id and s.status='active';

  if v_account_id is null then raise exception 'TARGET_SPACE_NOT_FOUND'; end if;
  if v_space_owner <> v_user then raise exception 'SPACE_OWNER_REQUIRED'; end if;

  select a.public_account_id into v_account_public_id
  from public.accounts a where a.id=v_account_id and a.status='active';

  select p.rupkas_id into v_profile_rupkas_id
  from public.profiles p where p.id=v_user;

  if v_account_public_id is null or v_profile_rupkas_id is null then raise exception 'RUPKAS_IDENTITY_NOT_READY'; end if;
  if (p_payload->'origin'->>'master_account_id') <> v_account_public_id
     or (p_payload->'origin'->>'rupkas_id') <> v_profile_rupkas_id then
    raise exception 'RKP_IDENTITY_MISMATCH';
  end if;

  if v_space_type <> (p_payload->'space'->>'type') then raise exception 'RKP_SPACE_TYPE_MISMATCH'; end if;

  select count(*) into v_existing_count from public.transactions where space_id=p_target_space_id;
  v_existing_count := v_existing_count + (select count(*) from public.debts where space_id=p_target_space_id);
  v_existing_count := v_existing_count + (select count(*) from public.savings_goals where space_id=p_target_space_id);
  v_existing_count := v_existing_count + (select count(*) from public.fixed_bills where space_id=p_target_space_id);
  v_existing_count := v_existing_count + (select count(*) from public.budgets where space_id=p_target_space_id);
  if v_existing_count > 0 then raise exception 'TARGET_SPACE_NOT_EMPTY'; end if;

  for r in select value from jsonb_array_elements(coalesce(p_payload->'data'->'categories','[]'::jsonb)) where value->>'parent_key' is null loop
    insert into public.categories(space_id,type,parent_id,name,is_system,is_active)
    values(p_target_space_id,(r->>'type')::tx_type,null,trim(r->>'name'),coalesce((r->>'is_system')::boolean,false),true)
    returning id into v_id;
    v_cat_map := v_cat_map || jsonb_build_object(r->>'key',v_id::text);
    v_count_categories := v_count_categories + 1;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_payload->'data'->'categories','[]'::jsonb)) where value->>'parent_key' is not null loop
    v_category_key := r->>'parent_key';
    if not (v_cat_map ? v_category_key) then raise exception 'RKP_CATEGORY_PARENT_MISSING'; end if;
    v_parent_id := (v_cat_map->>v_category_key)::uuid;
    insert into public.categories(space_id,type,parent_id,name,is_system,is_active)
    values(p_target_space_id,(r->>'type')::tx_type,v_parent_id,trim(r->>'name'),coalesce((r->>'is_system')::boolean,false),true)
    returning id into v_id;
    v_cat_map := v_cat_map || jsonb_build_object(r->>'key',v_id::text);
    v_count_categories := v_count_categories + 1;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_payload->'data'->'transactions','[]'::jsonb)) loop
    if (r->>'category_key') is null or not (v_cat_map ? r->>'category_key') then raise exception 'RKP_TRANSACTION_CATEGORY_MISSING'; end if;
    insert into public.transactions(space_id,type,status,amount,currency_code,category_id,transaction_date,transaction_time,source_text,note,created_by,updated_by,version,client_operation_id)
    values(p_target_space_id,(r->>'type')::tx_type,(r->>'status')::tx_status,(r->>'amount')::numeric,
           coalesce(nullif(r->>'currency',''),'IDR'),(v_cat_map->>(r->>'category_key'))::uuid,(r->>'date')::date,
           case when nullif(r->>'time','') is null then null else (r->>'time')::time end,nullif(r->>'source',''),nullif(r->>'note',''),
           v_user,v_user,1,null);
    v_count_transactions := v_count_transactions + 1;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_payload->'data'->'debts','[]'::jsonb)) loop
    insert into public.debts(space_id,direction,party_name,original_amount,due_date,status,note,created_by,version)
    values(p_target_space_id,(r->>'direction')::debt_direction,trim(r->>'party_name'),(r->>'original_amount')::numeric,
           case when nullif(r->>'due_date','') is null then null else (r->>'due_date')::date end,
           coalesce(nullif(r->>'status',''),'unpaid'),nullif(r->>'note',''),v_user,1);
    v_count_debts := v_count_debts + 1;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_payload->'data'->'savings_goals','[]'::jsonb)) loop
    insert into public.savings_goals(space_id,name,target_amount,target_date,status,created_by)
    values(p_target_space_id,trim(r->>'name'),(r->>'target_amount')::numeric,
           case when nullif(r->>'target_date','') is null then null else (r->>'target_date')::date end,
           coalesce(nullif(r->>'status',''),'active'),v_user)
    returning id into v_goal_id;
    v_goal_map := v_goal_map || jsonb_build_object(r->>'key',v_goal_id::text);
    v_count_goals := v_count_goals + 1;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_payload->'data'->'savings_movements','[]'::jsonb)) loop
    if (r->>'goal_key') is null or not (v_goal_map ? r->>'goal_key') then raise exception 'RKP_SAVINGS_GOAL_MISSING'; end if;
    v_goal_id := (v_goal_map->>(r->>'goal_key'))::uuid;
    insert into public.savings_movements(goal_id,type,amount,movement_date,created_by,client_operation_id)
    values(v_goal_id,r->>'type',(r->>'amount')::numeric,(r->>'date')::date,v_user,gen_random_uuid());
    v_count_movements := v_count_movements + 1;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_payload->'data'->'fixed_bills','[]'::jsonb)) loop
    insert into public.fixed_bills(space_id,name,default_amount,frequency,next_due_date,reminder_days_before,status,created_by,category_id,amount_type,day_of_period,responsible_user_id)
    values(p_target_space_id,trim(r->>'name'),
           case when nullif(r->>'default_amount','') is null then null else (r->>'default_amount')::numeric end,
           r->>'frequency',(r->>'next_due_date')::date,coalesce((r->>'reminder_days_before')::int,3),
           coalesce(nullif(r->>'status',''),'active'),v_user,
           case when nullif(r->>'category_key','') is null then null else (v_cat_map->>(r->>'category_key'))::uuid end,
           coalesce(nullif(r->>'amount_type',''),'fixed'),
           case when nullif(r->>'day_of_period','') is null then null else (r->>'day_of_period')::int end,v_user);
    v_count_bills := v_count_bills + 1;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_payload->'data'->'budgets','[]'::jsonb)) loop
    insert into public.budgets(space_id,period_start,period_end,limit_amount,warning_percent,name,amount,status,created_by)
    values(p_target_space_id,(r->>'period_start')::date,(r->>'period_end')::date,(r->>'limit_amount')::numeric,
           case when nullif(r->>'warning_percent','') is null then null else (r->>'warning_percent')::numeric end,
           nullif(r->>'name',''),case when nullif(r->>'amount','') is null then null else (r->>'amount')::numeric end,
           coalesce(nullif(r->>'status',''),'active'),v_user);
    v_count_budgets := v_count_budgets + 1;
  end loop;

  insert into private.rupkas_audit_events(account_id,actor_type,actor_user_id,event_type,entity_type,entity_id,metadata)
  values(v_account_id,'USER',v_user,'RKP_RESTORE_COMPLETED','SPACE',p_target_space_id,
         jsonb_build_object('origin_master_account_id',v_account_public_id,'origin_rupkas_id',v_profile_rupkas_id,
           'categories',v_count_categories,'transactions',v_count_transactions,'debts',v_count_debts,'savings_goals',v_count_goals,
           'savings_movements',v_count_movements,'fixed_bills',v_count_bills,'budgets',v_count_budgets));

  return jsonb_build_object('ok',true,'space_id',p_target_space_id,
    'counts',jsonb_build_object('categories',v_count_categories,'transactions',v_count_transactions,'debts',v_count_debts,
      'savings_goals',v_count_goals,'savings_movements',v_count_movements,'fixed_bills',v_count_bills,'budgets',v_count_budgets));
end;
$$;

revoke all on function public.rupkas_restore_rkp_payload(uuid,jsonb) from public;
grant execute on function public.rupkas_restore_rkp_payload(uuid,jsonb) to authenticated;
