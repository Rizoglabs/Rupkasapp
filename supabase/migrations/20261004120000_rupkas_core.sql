create extension if not exists pgcrypto;

do $$ begin
  create type public.space_type as enum ('personal','family');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.member_role as enum ('owner','member');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.member_status as enum ('active','removed');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.tx_type as enum ('income','expense');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.tx_status as enum ('confirmed','voided');
exception when duplicate_object then null; end $$;

create schema if not exists private;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 1 and 120),
  timezone text not null default 'Asia/Jakarta',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.spaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 120),
  type public.space_type not null,
  owner_user_id uuid not null references auth.users(id),
  status text not null default 'active' check (status in ('active','archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists spaces_one_personal on public.spaces(owner_user_id)
where type='personal' and status='active';

create table if not exists public.space_members (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.member_role not null,
  status public.member_status not null default 'active',
  joined_at timestamptz not null default now(),
  unique(space_id,user_id)
);
create index if not exists space_members_user_status_idx on public.space_members(user_id,status);

create table if not exists public.invitations (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  code_hash text not null unique,
  expires_at timestamptz not null,
  max_redemptions integer not null default 10,
  redemption_count integer not null default 0,
  status text not null default 'active' check(status in ('active','expired','revoked','exhausted')),
  created_at timestamptz not null default now()
);

create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete cascade,
  type public.tx_type not null,
  name text not null check (char_length(trim(name)) between 1 and 80),
  is_active boolean not null default true,
  unique(space_id,type,name)
);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete cascade,
  type public.tx_type not null,
  status public.tx_status not null default 'confirmed',
  amount numeric(18,2) not null check(amount > 0),
  currency_code text not null default 'IDR' check(currency_code='IDR'),
  category_id uuid not null references public.categories(id),
  transaction_date date not null,
  transaction_time time null,
  note text null,
  created_by uuid not null references auth.users(id),
  updated_by uuid not null references auth.users(id),
  version integer not null default 1,
  client_operation_id uuid unique null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists transactions_space_date_idx on public.transactions(space_id,transaction_date desc);

create table if not exists public.budgets (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  limit_amount numeric(18,2) not null check(limit_amount > 0),
  warning_percent numeric(5,2) null,
  unique(space_id,period_start,period_end)
);

create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid null references auth.users(id),
  space_id uuid null references public.spaces(id) on delete cascade,
  entity_type text not null,
  entity_id uuid null,
  action text not null,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

create or replace function private.is_member(p_space uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(
  select 1 from public.space_members m
  where m.space_id=p_space and m.user_id=(select auth.uid()) and m.status='active'
); $$;

create or replace function private.is_owner(p_space uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(
  select 1 from public.space_members m
  where m.space_id=p_space and m.user_id=(select auth.uid()) and m.status='active' and m.role='owner'
); $$;

create or replace function private.is_verified()
returns boolean language sql stable security definer set search_path=public,auth
as $$ select exists(
  select 1 from auth.users u
  where u.id=(select auth.uid()) and u.email_confirmed_at is not null
); $$;

alter table public.profiles enable row level security;
alter table public.spaces enable row level security;
alter table public.space_members enable row level security;
alter table public.invitations enable row level security;
alter table public.categories enable row level security;
alter table public.transactions enable row level security;
alter table public.budgets enable row level security;
alter table public.audit_logs enable row level security;

grant select,update on public.profiles to authenticated;
grant select on public.spaces,public.space_members,public.invitations,public.categories,public.transactions,public.budgets,public.audit_logs to authenticated;

drop policy if exists profiles_self_select on public.profiles;
create policy profiles_self_select on public.profiles for select to authenticated using ((select auth.uid())=id);
drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update on public.profiles for update to authenticated using ((select auth.uid())=id) with check ((select auth.uid())=id);

drop policy if exists spaces_member_select on public.spaces;
create policy spaces_member_select on public.spaces for select to authenticated using (private.is_member(id));
drop policy if exists spaces_owner_update on public.spaces;
create policy spaces_owner_update on public.spaces for update to authenticated using (private.is_owner(id)) with check (private.is_owner(id));

drop policy if exists members_select on public.space_members;
create policy members_select on public.space_members for select to authenticated using (private.is_member(space_id));
drop policy if exists invites_owner_select on public.invitations;
create policy invites_owner_select on public.invitations for select to authenticated using (private.is_owner(space_id));
drop policy if exists categories_select on public.categories;
create policy categories_select on public.categories for select to authenticated using (private.is_member(space_id));
drop policy if exists transactions_select on public.transactions;
create policy transactions_select on public.transactions for select to authenticated using (private.is_member(space_id));
drop policy if exists budgets_select on public.budgets;
create policy budgets_select on public.budgets for select to authenticated using (private.is_member(space_id));
drop policy if exists audit_owner_select on public.audit_logs;
create policy audit_owner_select on public.audit_logs for select to authenticated using (space_id is null or private.is_owner(space_id));

create or replace function public.create_family_space(p_name text)
returns public.spaces language plpgsql security invoker set search_path=public,private
as $$ declare v public.spaces; begin
  if not private.is_verified() then raise exception 'EMAIL_NOT_VERIFIED'; end if;
  insert into public.spaces(name,type,owner_user_id) values(trim(p_name),'family',(select auth.uid())) returning * into v;
  insert into public.space_members(space_id,user_id,role) values(v.id,(select auth.uid()),'owner');
  insert into public.categories(space_id,type,name) values
    (v.id,'expense','Makanan'),(v.id,'expense','Transportasi'),(v.id,'expense','Tagihan'),(v.id,'expense','Belanja'),
    (v.id,'income','Gaji'),(v.id,'income','Bonus'),(v.id,'income','Lainnya')
    on conflict do nothing;
  return v;
end; $$;
grant execute on function public.create_family_space(text) to authenticated;

create or replace function public.create_invitation(p_space_id uuid,p_ttl_hours integer default 168)
returns text language plpgsql security invoker set search_path=public,private
as $$ declare c text; begin
  if not private.is_owner(p_space_id) then raise exception 'FORBIDDEN'; end if;
  c:=upper(encode(gen_random_bytes(6),'hex'));
  insert into public.invitations(space_id,created_by,code_hash,expires_at)
  values(p_space_id,(select auth.uid()),encode(digest(c,'sha256'),'hex'),now()+make_interval(hours=>p_ttl_hours));
  return c;
end; $$;
grant execute on function public.create_invitation(uuid,integer) to authenticated;

create or replace function public.claim_invitation(p_code text)
returns public.space_members language plpgsql security invoker set search_path=public,private
as $$ declare i public.invitations; m public.space_members; begin
  if not private.is_verified() then raise exception 'EMAIL_NOT_VERIFIED'; end if;
  select * into i from public.invitations where code_hash=encode(digest(upper(trim(p_code)),'sha256'),'hex') for update;
  if not found or i.status<>'active' or i.expires_at<now() or i.redemption_count>=i.max_redemptions then raise exception 'INVALID_INVITATION'; end if;
  insert into public.space_members(space_id,user_id,role) values(i.space_id,(select auth.uid()),'member')
  on conflict(space_id,user_id) do update set status='active';
  update public.invitations
  set redemption_count=redemption_count+1,
      status=case when redemption_count+1>=max_redemptions then 'exhausted' else status end
  where id=i.id;
  select * into m from public.space_members where space_id=i.space_id and user_id=(select auth.uid());
  return m;
end; $$;
grant execute on function public.claim_invitation(text) to authenticated;

create or replace function public.create_transaction(
  p_space_id uuid,p_type public.tx_type,p_amount numeric,p_category_id uuid,p_transaction_date date,
  p_transaction_time time default null,p_note text default null,p_client_operation_id uuid default null
) returns public.transactions language plpgsql security invoker set search_path=public,private
as $$ declare v public.transactions; begin
  if not private.is_member(p_space_id) then raise exception 'FORBIDDEN'; end if;
  if not exists(select 1 from public.categories c where c.id=p_category_id and c.space_id=p_space_id and c.type=p_type and c.is_active) then raise exception 'INVALID_CATEGORY'; end if;
  if p_client_operation_id is not null then
    select * into v from public.transactions where client_operation_id=p_client_operation_id;
    if found then return v; end if;
  end if;
  insert into public.transactions(space_id,type,amount,category_id,transaction_date,transaction_time,note,created_by,updated_by,client_operation_id)
  values(p_space_id,p_type,p_amount,p_category_id,p_transaction_date,p_transaction_time,p_note,(select auth.uid()),(select auth.uid()),p_client_operation_id)
  returning * into v;
  return v;
end; $$;
grant execute on function public.create_transaction(uuid,public.tx_type,numeric,uuid,date,time,text,uuid) to authenticated;

create or replace function public.void_transaction(p_transaction_id uuid,p_expected_version integer,p_reason text)
returns public.transactions language plpgsql security invoker set search_path=public,private
as $$ declare old public.transactions; v public.transactions; begin
  select * into old from public.transactions where id=p_transaction_id for update;
  if not found or not private.is_member(old.space_id) then raise exception 'FORBIDDEN'; end if;
  if old.version<>p_expected_version then raise exception 'CONFLICT'; end if;
  if old.created_by<>(select auth.uid()) and not private.is_owner(old.space_id) then raise exception 'FORBIDDEN'; end if;
  update public.transactions
  set status='voided',version=version+1,updated_by=(select auth.uid()),updated_at=now(),
      note=coalesce(note||' | ','')||'Void: '||coalesce(nullif(p_reason,''),'Koreksi')
  where id=old.id returning * into v;
  return v;
end; $$;
grant execute on function public.void_transaction(uuid,integer,text) to authenticated;

create or replace function public.upsert_budget(p_space_id uuid,p_period_start date,p_period_end date,p_limit numeric,p_warning_percent numeric default 80)
returns public.budgets language plpgsql security invoker set search_path=public,private
as $$ declare v public.budgets; begin
  if not private.is_member(p_space_id) then raise exception 'FORBIDDEN'; end if;
  insert into public.budgets(space_id,period_start,period_end,limit_amount,warning_percent)
  values(p_space_id,p_period_start,p_period_end,p_limit,p_warning_percent)
  on conflict(space_id,period_start,period_end)
  do update set limit_amount=excluded.limit_amount,warning_percent=excluded.warning_percent
  returning * into v;
  return v;
end; $$;
grant execute on function public.upsert_budget(uuid,date,date,numeric,numeric) to authenticated;

create or replace function public.get_month_summary(p_space_id uuid,p_month_start date)
returns table(income_total numeric,expense_total numeric,net_cashflow numeric,budget_limit numeric,budget_actual numeric,budget_utilization numeric)
language sql security invoker set search_path=public,private
as $$
with tx as (
  select coalesce(sum(amount) filter(where type='income' and status='confirmed'),0) income_total,
         coalesce(sum(amount) filter(where type='expense' and status='confirmed'),0) expense_total
  from public.transactions
  where space_id=p_space_id and transaction_date>=p_month_start and transaction_date<(p_month_start+interval '1 month')
),
b as (
  select coalesce(limit_amount,0) budget_limit
  from public.budgets
  where space_id=p_space_id and p_month_start between period_start and period_end
  limit 1
)
select tx.income_total,tx.expense_total,tx.income_total-tx.expense_total,b.budget_limit,tx.expense_total,
case when b.budget_limit>0 then round(tx.expense_total/b.budget_limit*100,2) else 0 end
from tx cross join b;
$$;
grant execute on function public.get_month_summary(uuid,date) to authenticated;

create or replace function private.provision_verified_user()
returns trigger language plpgsql security definer set search_path=public,private,auth
as $$ declare v_space uuid; v_name text; begin
  if new.email_confirmed_at is null or old.email_confirmed_at is not null then return new; end if;
  v_name:=coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'),''),split_part(coalesce(new.email,''),'@',1),'Pengguna Rupkas');
  insert into public.profiles(id,display_name) values(new.id,v_name)
  on conflict(id) do update set display_name=excluded.display_name,updated_at=now();
  insert into public.spaces(name,type,owner_user_id) values('Pribadi','personal',new.id)
  on conflict do nothing returning id into v_space;
  if v_space is null then select id into v_space from public.spaces where owner_user_id=new.id and type='personal' and status='active' limit 1; end if;
  insert into public.space_members(space_id,user_id,role) values(v_space,new.id,'owner') on conflict do nothing;
  insert into public.categories(space_id,type,name) values
    (v_space,'expense','Makanan'),(v_space,'expense','Transportasi'),(v_space,'expense','Tagihan'),(v_space,'expense','Belanja'),
    (v_space,'income','Gaji'),(v_space,'income','Bonus'),(v_space,'income','Lainnya')
  on conflict do nothing;
  return new;
end; $$;

drop trigger if exists rupkas_after_email_verified on auth.users;
create trigger rupkas_after_email_verified
after update of email_confirmed_at on auth.users
for each row execute function private.provision_verified_user();
