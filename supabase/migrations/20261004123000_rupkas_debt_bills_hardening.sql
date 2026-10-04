create table if not exists public.debts (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete cascade,
  direction text not null check(direction in ('receivable','payable')),
  person_name text not null check(char_length(trim(person_name)) between 1 and 120),
  title text not null check(char_length(trim(title)) between 1 and 160),
  principal numeric(18,2) not null check(principal > 0),
  due_date date,
  note text,
  status text not null default 'open' check(status in ('open','settled','cancelled')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists debts_space_status_idx on public.debts(space_id,status);
create table if not exists public.bills (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete cascade,
  name text not null check(char_length(trim(name)) between 1 and 120),
  amount numeric(18,2) not null check(amount > 0),
  due_day integer not null check(due_day between 1 and 31),
  category_id uuid references public.categories(id),
  is_active boolean not null default true,
  note text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists bills_space_active_idx on public.bills(space_id,is_active);
alter table public.debts enable row level security;
alter table public.bills enable row level security;
grant select on public.debts,public.bills to authenticated;
drop policy if exists debts_select on public.debts;
create policy debts_select on public.debts for select to authenticated using ((select private.is_member(space_id)));
drop policy if exists bills_select on public.bills;
create policy bills_select on public.bills for select to authenticated using ((select private.is_member(space_id)));
drop policy if exists audit_owner_select on public.audit_logs;
create policy audit_owner_select on public.audit_logs for select to authenticated using (space_id is null or (select private.is_owner(space_id)));
create or replace function public.create_debt(p_space_id uuid,p_direction text,p_person_name text,p_title text,p_principal numeric,p_due_date date default null,p_note text default null)
returns public.debts language plpgsql security invoker set search_path=public,private
as $$ declare v public.debts; begin
 if not private.is_member(p_space_id) then raise exception 'FORBIDDEN'; end if;
 if p_direction not in ('receivable','payable') then raise exception 'INVALID_DIRECTION'; end if;
 insert into public.debts(space_id,direction,person_name,title,principal,due_date,note,created_by)
 values(p_space_id,p_direction,trim(p_person_name),trim(p_title),p_principal,p_due_date,p_note,(select auth.uid())) returning * into v;
 return v;
end; $$;
grant execute on function public.create_debt(uuid,text,text,text,numeric,date,text) to authenticated;
create or replace function public.create_bill(p_space_id uuid,p_name text,p_amount numeric,p_due_day integer,p_category_id uuid default null,p_note text default null)
returns public.bills language plpgsql security invoker set search_path=public,private
as $$ declare v public.bills; begin
 if not private.is_member(p_space_id) then raise exception 'FORBIDDEN'; end if;
 if p_category_id is not null and not exists(select 1 from public.categories c where c.id=p_category_id and c.space_id=p_space_id and c.type='expense' and c.is_active) then raise exception 'INVALID_CATEGORY'; end if;
 insert into public.bills(space_id,name,amount,due_day,category_id,note,created_by)
 values(p_space_id,trim(p_name),p_amount,p_due_day,p_category_id,p_note,(select auth.uid())) returning * into v;
 return v;
end; $$;
grant execute on function public.create_bill(uuid,text,numeric,integer,uuid,text) to authenticated;
create or replace function public.settle_debt(p_debt_id uuid)
returns public.debts language plpgsql security invoker set search_path=public,private
as $$ declare v public.debts; begin
 update public.debts set status='settled',updated_at=now() where id=p_debt_id and private.is_member(space_id) and status='open' returning * into v;
 if not found then raise exception 'NOT_FOUND_OR_FORBIDDEN'; end if;
 return v;
end; $$;
grant execute on function public.settle_debt(uuid) to authenticated;
create or replace function public.get_month_summary(p_space_id uuid,p_month_start date)
returns table(income_total numeric,expense_total numeric,net_cashflow numeric,budget_limit numeric,budget_actual numeric,budget_utilization numeric)
language sql security invoker set search_path=public,private
as $$
with tx as (select coalesce(sum(amount) filter(where type='income' and status='confirmed'),0) income_total, coalesce(sum(amount) filter(where type='expense' and status='confirmed'),0) expense_total from public.transactions where space_id=p_space_id and transaction_date>=p_month_start and transaction_date<(p_month_start+interval '1 month')),
b as (select coalesce((select limit_amount from public.budgets where space_id=p_space_id and p_month_start between period_start and period_end order by period_start desc limit 1),0) budget_limit)
select tx.income_total,tx.expense_total,tx.income_total-tx.expense_total,b.budget_limit,tx.expense_total,case when b.budget_limit>0 then round(tx.expense_total/b.budget_limit*100,2) else 0 end from tx cross join b;
$$;
drop trigger if exists rupkas_after_email_verified on auth.users;
create or replace function private.provision_verified_user()
returns trigger language plpgsql security definer set search_path=public,private,auth
as $$ declare v_space uuid; v_name text; begin
 if new.email_confirmed_at is null then return new; end if;
 v_name:=coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'),''),split_part(coalesce(new.email,''),'@',1),'Pengguna Rupkas');
 insert into public.profiles(id,display_name) values(new.id,v_name) on conflict(id) do update set display_name=excluded.display_name,updated_at=now();
 insert into public.spaces(name,type,owner_user_id) values('Pribadi','personal',new.id) on conflict do nothing returning id into v_space;
 if v_space is null then select id into v_space from public.spaces where owner_user_id=new.id and type='personal' and status='active' limit 1; end if;
 insert into public.space_members(space_id,user_id,role) values(v_space,new.id,'owner') on conflict do nothing;
 insert into public.categories(space_id,type,name) values (v_space,'expense','Makanan'),(v_space,'expense','Transportasi'),(v_space,'expense','Tagihan'),(v_space,'expense','Belanja'),(v_space,'income','Gaji'),(v_space,'income','Bonus'),(v_space,'income','Lainnya') on conflict do nothing;
 return new;
end; $$;
create trigger rupkas_after_email_verified after insert or update of email_confirmed_at on auth.users for each row execute function private.provision_verified_user();
alter publication supabase_realtime add table public.debts, public.bills;
