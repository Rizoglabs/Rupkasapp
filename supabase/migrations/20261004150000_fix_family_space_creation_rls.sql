-- Fix Family Space creation under RLS.
-- The RPC performs a controlled multi-table provisioning flow, so it must
-- execute with the function owner's privileges while keeping explicit
-- verification and name validation checks.

create or replace function public.create_family_space(p_name text)
returns public.spaces
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v public.spaces;
begin
  if not private.is_verified() then
    raise exception 'EMAIL_NOT_VERIFIED';
  end if;

  if not exists (
    select 1
    from auth.users
    where id = (select auth.uid())
  ) then
    raise exception 'UNAUTHENTICATED';
  end if;

  if char_length(trim(p_name)) < 1 or char_length(trim(p_name)) > 120 then
    raise exception 'INVALID_SPACE_NAME';
  end if;

  insert into public.spaces(name,type,owner_user_id)
  values(trim(p_name),'family',(select auth.uid()))
  returning * into v;

  insert into public.space_members(space_id,user_id,role)
  values(v.id,(select auth.uid()),'owner');

  insert into public.categories(space_id,type,name)
  values
    (v.id,'expense','Makanan'),
    (v.id,'expense','Transportasi'),
    (v.id,'expense','Tagihan'),
    (v.id,'expense','Belanja'),
    (v.id,'income','Gaji'),
    (v.id,'income','Bonus'),
    (v.id,'income','Lainnya')
  on conflict do nothing;

  return v;
end;
$$;

revoke all on function public.create_family_space(text) from public;
grant execute on function public.create_family_space(text) to authenticated;
