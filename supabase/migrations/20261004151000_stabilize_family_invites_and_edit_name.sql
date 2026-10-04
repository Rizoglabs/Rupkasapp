-- Stabilize Family invitation generation and add Owner-only Family name editing.
-- The project has pgcrypto helpers installed in the "extensions" schema.
-- Explicit qualification keeps RPC behavior independent of search_path.

create or replace function public.create_invitation(
  p_space_id uuid,
  p_ttl_hours integer default 168
)
returns text
language plpgsql
security definer
set search_path = public, private
as $$
declare
  c text;
  ttl integer;
begin
  if not private.is_owner(p_space_id) then
    raise exception 'FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.spaces
    where id = p_space_id
      and type = 'family'
      and status = 'active'
  ) then
    raise exception 'INVALID_FAMILY_SPACE';
  end if;

  ttl := greatest(1, least(coalesce(p_ttl_hours, 168), 168));

  update public.invitations
  set status = 'revoked'
  where space_id = p_space_id
    and status = 'active';

  c := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

  insert into public.invitations(
    space_id, created_by, code_hash, expires_at,
    max_redemptions, redemption_count, status
  )
  values(
    p_space_id,
    (select auth.uid()),
    encode(extensions.digest(c, 'sha256'), 'hex'),
    now() + make_interval(hours => ttl),
    10, 0, 'active'
  );

  return c;
end;
$$;

revoke all on function public.create_invitation(uuid, integer) from public;
grant execute on function public.create_invitation(uuid, integer) to authenticated;


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
    select 1 from auth.users
    where id = uid and email_confirmed_at is not null
  ) then
    raise exception 'EMAIL_NOT_VERIFIED';
  end if;

  select * into i
  from public.invitations
  where code_hash = encode(extensions.digest(upper(trim(p_code)), 'sha256'), 'hex')
  for update;

  if not found
     or i.status <> 'active'
     or i.expires_at < now()
     or i.redemption_count >= i.max_redemptions then
    raise exception 'INVALID_INVITATION';
  end if;

  h := i.space_id;

  select * into m
  from public.space_members
  where space_id = h and user_id = uid
  for update;

  if found and m.status = 'active' then
    return m;
  end if;

  if found then
    update public.space_members
    set status = 'active'
    where id = m.id
    returning * into m;
  else
    insert into public.space_members(space_id,user_id,role)
    values(h,uid,'member')
    returning * into m;
  end if;

  update public.invitations
  set redemption_count = redemption_count + 1,
      status = case
        when redemption_count + 1 >= max_redemptions then 'exhausted'
        else 'active'
      end
  where id = i.id;

  return m;
end;
$$;

revoke all on function public.claim_invitation(text) from public;
grant execute on function public.claim_invitation(text) to authenticated;


create or replace function public.update_family_space_name(
  p_space_id uuid,
  p_name text
)
returns public.spaces
language plpgsql
security invoker
set search_path = public, private
as $$
declare
  v public.spaces;
begin
  if not private.is_owner(p_space_id) then
    raise exception 'FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.spaces
    where id = p_space_id
      and type = 'family'
      and status = 'active'
  ) then
    raise exception 'INVALID_FAMILY_SPACE';
  end if;

  if char_length(trim(p_name)) < 1
     or char_length(trim(p_name)) > 120 then
    raise exception 'INVALID_SPACE_NAME';
  end if;

  update public.spaces
  set name = trim(p_name),
      updated_at = now()
  where id = p_space_id
  returning * into v;

  if not found then
    raise exception 'FAMILY_SPACE_NOT_FOUND';
  end if;

  return v;
end;
$$;

revoke all on function public.update_family_space_name(uuid, text) from public;
grant execute on function public.update_family_space_name(uuid, text) to authenticated;
