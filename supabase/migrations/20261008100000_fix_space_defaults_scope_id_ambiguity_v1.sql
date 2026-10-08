create or replace function private.provision_space_defaults()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_scope_id uuid;
  owner_role uuid;
  member_role uuid;
  c public.categories;
begin
  insert into public.roles(space_id,name,description,is_system,is_active)
  values(new.id,'Owner','Governance penuh',true,true)
  on conflict(space_id,name) do update set is_active=true
  returning id into owner_role;

  insert into public.roles(space_id,name,description,is_system,is_active)
  values(new.id,'Member','Akses operasional dasar',true,true)
  on conflict(space_id,name) do update set is_active=true
  returning id into member_role;

  insert into public.role_permissions(role_id,permission_key,effect)
  select owner_role,v.key,'allow' from (values
    ('VIEW_TRANSACTION'),('CREATE_TRANSACTION'),('EDIT_TRANSACTION'),('VOID_TRANSACTION'),('VIEW_REPORT'),
    ('MANAGE_BILL'),('MANAGE_BUDGET'),('MANAGE_CATEGORY'),('MANAGE_PAYMENT_METHOD'),
    ('MANAGE_MEMBER'),('MANAGE_ROLE'),('MANAGE_PERMISSION'),('MANAGE_SCOPE')
  ) v(key) on conflict do nothing;

  insert into public.role_permissions(role_id,permission_key,effect)
  select member_role,v.key,v.effect from (values
    ('VIEW_TRANSACTION','allow'),('CREATE_TRANSACTION','allow'),('EDIT_TRANSACTION','allow'),
    ('VIEW_REPORT','allow'),('MANAGE_BILL','allow'),('MANAGE_BUDGET','allow'),
    ('MANAGE_CATEGORY','allow'),('MANAGE_PAYMENT_METHOD','allow'),
    ('VOID_TRANSACTION','deny'),('MANAGE_MEMBER','deny'),('MANAGE_ROLE','deny'),
    ('MANAGE_PERMISSION','deny'),('MANAGE_SCOPE','deny')
  ) v(key,effect) on conflict(role_id,permission_key) do update set effect=excluded.effect;

  insert into public.space_members(space_id,user_id,role,role_id,status)
  values(new.id,new.owner_user_id,'owner',owner_role,'active')
  on conflict(space_id,user_id) do update set role='owner',role_id=owner_role,status='active';

  insert into public.scopes(space_id,name,description,status)
  values(new.id,'Utama','Ruang Keuangan utama','active')
  on conflict(space_id,name) do update set status='active'
  returning id into v_scope_id;

  insert into public.scope_members(scope_id,user_id,status)
  values(v_scope_id,new.owner_user_id,'active')
  on conflict(scope_id,user_id) do update set status='active';

  insert into public.categories(space_id,scope_id,type,name,is_system,is_active)
  select new.id,v_scope_id,v.type::public.tx_type,v.name,true,true
  from (values
    ('expense','Makanan'),('expense','Transportasi'),('expense','Belanja'),('expense','Tagihan'),
    ('expense','Pendidikan'),('expense','Kesehatan'),('expense','Lainnya'),
    ('income','Gaji'),('income','Bonus'),('income','Penjualan'),('income','Uang Saku'),('income','Pendapatan Lain')
  ) v(type,name)
  where not exists(
    select 1
    from public.categories x
    where x.space_id=new.id
      and x.scope_id=v_scope_id
      and x.type=v.type::public.tx_type
      and x.name=v.name
  );

  insert into public.payment_methods(scope_id,name,type,is_default,status)
  select v_scope_id,v.name,v.type,(v.name='Tunai'),'active'
  from (values
    ('Tunai','cash'),('Transfer','bank_transfer'),('Dompet Digital','ewallet'),('QRIS','qris'),('Hutang','debt')
  ) v(name,type)
  on conflict(scope_id,name) do nothing;

  return new;
end;
$function$;
