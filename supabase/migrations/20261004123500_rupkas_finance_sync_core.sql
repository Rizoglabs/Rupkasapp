create extension if not exists pgcrypto;

create index if not exists debt_payments_debt_id_idx on public.debt_payments(debt_id);
create index if not exists debt_payments_created_by_idx on public.debt_payments(created_by);
create index if not exists savings_movements_goal_id_idx on public.savings_movements(goal_id);
create index if not exists savings_movements_created_by_idx on public.savings_movements(created_by);
create index if not exists savings_goals_space_status_idx on public.savings_goals(space_id,status);
create index if not exists fixed_bills_space_status_idx on public.fixed_bills(space_id,status);
create index if not exists fixed_bills_created_by_idx on public.fixed_bills(created_by);
create index if not exists bill_occurrences_fixed_bill_id_idx on public.bill_occurrences(fixed_bill_id);
create index if not exists bill_payments_occurrence_id_idx on public.bill_payments(occurrence_id);
create index if not exists bill_payments_created_by_idx on public.bill_payments(created_by);
create index if not exists audit_logs_actor_user_id_idx on public.audit_logs(actor_user_id);
create index if not exists audit_logs_space_id_idx on public.audit_logs(space_id);
create index if not exists entity_revisions_space_id_idx on public.entity_revisions(space_id);
create index if not exists entity_revisions_changed_by_idx on public.entity_revisions(changed_by);
create index if not exists exports_requested_by_idx on public.exports(requested_by);
create index if not exists exports_space_id_idx on public.exports(space_id);
create index if not exists notification_preferences_space_id_idx on public.notification_preferences(space_id);
create index if not exists sync_operations_user_id_idx on public.sync_operations(user_id);
create index if not exists transaction_splits_transaction_id_idx on public.transaction_splits(transaction_id);
create index if not exists transaction_splits_category_id_idx on public.transaction_splits(category_id);
create index if not exists transaction_tags_tag_id_idx on public.transaction_tags(tag_id);
create index if not exists transactions_category_id_idx on public.transactions(category_id);
create index if not exists transactions_created_by_idx on public.transactions(created_by);
create index if not exists transactions_updated_by_idx on public.transactions(updated_by);
create unique index if not exists bill_occurrences_fixed_bill_period_uq on public.bill_occurrences(fixed_bill_id,period_key);
create index if not exists bills_space_active_idx on public.bills(space_id,is_active);
create index if not exists bills_category_id_idx on public.bills(category_id);
create index if not exists bills_created_by_idx on public.bills(created_by);
create index if not exists invitations_space_id_idx on public.invitations(space_id);
create index if not exists invitations_created_by_idx on public.invitations(created_by);
create index if not exists categories_space_id_idx on public.categories(space_id);
create index if not exists categories_parent_id_idx on public.categories(parent_id);

create or replace function public.create_savings_goal(p_space_id uuid,p_name text,p_target_amount numeric,p_target_date date default null) returns public.savings_goals
language plpgsql set search_path to 'public','private' as $$
declare v public.savings_goals;
begin
  if not private.is_member(p_space_id) then raise exception 'FORBIDDEN'; end if;
  if p_target_amount <= 0 then raise exception 'INVALID_TARGET'; end if;
  insert into public.savings_goals(space_id,name,target_amount,target_date,created_by)
  values(p_space_id,trim(p_name),p_target_amount,p_target_date,(select auth.uid())) returning * into v;
  return v;
end; $$;

create or replace function public.list_savings_goals(p_space_id uuid)
returns table(id uuid,space_id uuid,name text,target_amount numeric,target_date date,status text,saved_amount numeric,progress_percent numeric)
language sql stable set search_path to 'public','private' as $$
  select g.id,g.space_id,g.name,g.target_amount,g.target_date,g.status,
    coalesce(sum(case when m.type='deposit' then m.amount else -m.amount end),0),
    case when g.target_amount>0 then round((coalesce(sum(case when m.type='deposit' then m.amount else -m.amount end),0)/g.target_amount)*100,1) else 0 end
  from public.savings_goals g
  left join public.savings_movements m on m.goal_id=g.id
  where g.space_id=p_space_id and private.is_member(g.space_id)
  group by g.id,g.space_id,g.name,g.target_amount,g.target_date,g.status;
$$;

create or replace function public.add_savings_movement(p_goal_id uuid,p_type text,p_amount numeric,p_movement_date date default current_date,p_client_operation_id uuid default null) returns public.savings_movements
language plpgsql set search_path to 'public','private' as $$
declare v public.savings_movements; v_space uuid; v_balance numeric;
begin
  select space_id into v_space from public.savings_goals where id=p_goal_id;
  if v_space is null or not private.is_member(v_space) then raise exception 'FORBIDDEN'; end if;
  if p_type not in ('deposit','withdrawal') then raise exception 'INVALID_MOVEMENT_TYPE'; end if;
  if p_amount<=0 then raise exception 'INVALID_AMOUNT'; end if;
  if p_type='withdrawal' then
    select coalesce(sum(case when type='deposit' then amount else -amount end),0) into v_balance from public.savings_movements where goal_id=p_goal_id;
    if p_amount>v_balance then raise exception 'INSUFFICIENT_SAVINGS'; end if;
  end if;
  insert into public.savings_movements(goal_id,type,amount,movement_date,created_by,client_operation_id)
  values(p_goal_id,p_type,p_amount,p_movement_date,(select auth.uid()),p_client_operation_id)
  on conflict (client_operation_id) do update set client_operation_id=excluded.client_operation_id
  returning * into v;
  update public.savings_goals set status=case
    when (select coalesce(sum(case when type='deposit' then amount else -amount end),0) from public.savings_movements where goal_id=p_goal_id)>=target_amount then 'completed'
    when status='completed' and (select coalesce(sum(case when type='deposit' then amount else -amount end),0) from public.savings_movements where goal_id=p_goal_id)<target_amount then 'active'
    else status end
  where id=p_goal_id;
  return v;
end; $$;

create or replace function public.record_debt_payment(p_debt_id uuid,p_amount numeric,p_payment_date date default current_date,p_client_operation_id uuid default null) returns public.debts
language plpgsql set search_path to 'public','private' as $$
declare v public.debts; v_paid numeric; v_remaining numeric;
begin
  select * into v from public.debts where id=p_debt_id and private.is_member(space_id) for update;
  if v.id is null then raise exception 'NOT_FOUND_OR_FORBIDDEN'; end if;
  if v.status='voided' then raise exception 'DEBT_VOIDED'; end if;
  if p_amount<=0 then raise exception 'INVALID_AMOUNT'; end if;
  select coalesce(sum(amount),0) into v_paid from public.debt_payments where debt_id=p_debt_id;
  v_remaining:=greatest(v.original_amount-v_paid,0);
  if p_amount>v_remaining then raise exception 'PAYMENT_EXCEEDS_REMAINING'; end if;
  insert into public.debt_payments(debt_id,amount,payment_date,created_by,client_operation_id)
  values(p_debt_id,p_amount,p_payment_date,(select auth.uid()),p_client_operation_id)
  on conflict (client_operation_id) do nothing;
  select coalesce(sum(amount),0) into v_paid from public.debt_payments where debt_id=p_debt_id;
  update public.debts set status=case when v_paid>=original_amount then 'paid' else 'partial' end,version=version+1 where id=p_debt_id returning * into v;
  return v;
end; $$;

create or replace function public.ensure_bill_occurrence(p_fixed_bill_id uuid,p_period_key text,p_due_date date,p_scheduled_amount numeric default null) returns public.bill_occurrences
language plpgsql set search_path to 'public','private' as $$
declare v public.bill_occurrences;
begin
  if not exists(select 1 from public.fixed_bills b where b.id=p_fixed_bill_id and private.is_member(b.space_id)) then raise exception 'NOT_FOUND_OR_FORBIDDEN'; end if;
  insert into public.bill_occurrences(fixed_bill_id,period_key,scheduled_amount,due_date)
  values(p_fixed_bill_id,p_period_key,p_scheduled_amount,p_due_date)
  on conflict (fixed_bill_id,period_key) do update set scheduled_amount=coalesce(excluded.scheduled_amount,bill_occurrences.scheduled_amount),due_date=excluded.due_date
  returning * into v;
  return v;
end; $$;

create or replace function public.record_bill_payment(p_occurrence_id uuid,p_amount numeric,p_payment_date date default current_date) returns public.bill_occurrences
language plpgsql set search_path to 'public','private' as $$
declare v public.bill_occurrences; v_paid numeric; v_target numeric;
begin
  select o.* into v from public.bill_occurrences o join public.fixed_bills b on b.id=o.fixed_bill_id where o.id=p_occurrence_id and private.is_member(b.space_id) for update;
  if v.id is null then raise exception 'NOT_FOUND_OR_FORBIDDEN'; end if;
  if p_amount<=0 then raise exception 'INVALID_AMOUNT'; end if;
  v_target:=coalesce(v.scheduled_amount,0);
  select coalesce(sum(amount),0) into v_paid from public.bill_payments where occurrence_id=p_occurrence_id;
  if v_target>0 and p_amount>greatest(v_target-v_paid,0) then raise exception 'PAYMENT_EXCEEDS_REMAINING'; end if;
  insert into public.bill_payments(occurrence_id,amount,payment_date,created_by) values(p_occurrence_id,p_amount,p_payment_date,(select auth.uid()));
  select coalesce(sum(amount),0) into v_paid from public.bill_payments where occurrence_id=p_occurrence_id;
  update public.bill_occurrences set actual_amount=v_paid,status=case when v_target>0 and v_paid>=v_target then 'paid' when v_paid>0 then 'partial' when due_date<current_date then 'overdue' else 'unpaid' end where id=p_occurrence_id returning * into v;
  return v;
end; $$;

create or replace function public.create_fixed_bill(p_space_id uuid,p_name text,p_amount numeric,p_frequency text,p_next_due_date date,p_reminder_days integer default 3) returns public.fixed_bills
language plpgsql set search_path to 'public','private' as $$
declare v public.fixed_bills; v_period text;
begin
  if not private.is_member(p_space_id) then raise exception 'FORBIDDEN'; end if;
  if p_frequency not in ('monthly','weekly','yearly','custom') then raise exception 'INVALID_FREQUENCY'; end if;
  if p_amount<=0 then raise exception 'INVALID_AMOUNT'; end if;
  insert into public.fixed_bills(space_id,name,default_amount,frequency,next_due_date,reminder_days_before,created_by)
  values(p_space_id,trim(p_name),p_amount,p_frequency,p_next_due_date,p_reminder_days,(select auth.uid())) returning * into v;
  v_period:=to_char(p_next_due_date,'YYYY-MM');
  insert into public.bill_occurrences(fixed_bill_id,period_key,scheduled_amount,due_date) values(v.id,v_period,p_amount,p_next_due_date) on conflict (fixed_bill_id,period_key) do nothing;
  return v;
end; $$;
