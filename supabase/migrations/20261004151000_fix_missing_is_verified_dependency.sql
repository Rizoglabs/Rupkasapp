-- Fix Family RPCs so they do not depend on a missing private.is_verified() helper.
-- auth.users.email_confirmed_at is the authoritative verification state.

create or replace function public.create_family_space(p_name text)
returns public.spaces
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v public.spaces;
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'UNAUTHENTICATED';
  end if;

  if not exists (
    select 1 from auth.users u
    where u.id = uid and u.email_confirmed_at is not null
  ) then
    raise exception 'EMAIL_NOT_VERIFIED';
  end if;

  if char_length(trim(p_name)) < 1 or char_length(trim(p_name)) > 120 then
    raise exception 'INVALID_SPACE_NAME';
  end if;

  insert into public.spaces(name,type,owner_user_id)
  values(trim(p_name),'family',uid)
  returning * into v;

  insert into public.space_members(space_id,user_id,role)
  values(v.id,uid,'owner');

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

create or replace function public.claim_invitation(p_code text)
returns public.space_members
language plpgsql
security definer
set search_path = public, private
as $$
declare
  i public.invitations;
  m public.space_members;
  h uuid;
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'UNAUTHENTICATED';
  end if;

  if not exists (
    select 1 from auth.users u
    where u.id = uid and u.email_confirmed_at is not null
  ) then
    raise exception 'EMAIL_NOT_VERIFIED';
  end if;

  select * into i
  from public.invitations
  where code_hash = encode(digest(upper(trim(p_code)), 'sha256'), 'hex')
  for update;

  if not found or i.status <> 'active' or i.expires_at < now() or i.redemption_count >= i.max_redemptions then
    raise exception 'INVALID_INVITATION';
  end if;

  h := i.space_id;

  select * into m from public.space_members
  where space_id = h and user_id = uid for update;

  if found and m.status = 'active' then
    return m;
  end if;

  if found then
    update public.space_members set status = 'active' where id = m.id returning * into m;
  else
    insert into public.space_members(space_id,user_id,role)
    values(h,uid,'member') returning * into m;
  end if;

  update public.invitations
  set redemption_count = redemption_count + 1,
      status = case when redemption_count + 1 >= max_redemptions then 'exhausted' else 'active' end
  where id = i.id;

  return m;
end;
$$;

revoke all on function public.claim_invitation(text) from public;
grant execute on function public.claim_invitation(text) to authenticated;
