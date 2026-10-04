-- Harden Family invitation RPCs against RLS and make invite/join flows idempotent.
-- Invitation mutations span invitations + space_members, so they run with
-- controlled SECURITY DEFINER privileges while retaining explicit authorization.

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

  ttl := greatest(1, least(coalesce(p_ttl_hours, 168), 168));

  update public.invitations
  set status = 'revoked'
  where space_id = p_space_id
    and status = 'active';

  c := upper(encode(gen_random_bytes(6), 'hex'));

  insert into public.invitations(
    space_id,
    created_by,
    code_hash,
    expires_at,
    max_redemptions,
    redemption_count,
    status
  )
  values(
    p_space_id,
    (select auth.uid()),
    encode(digest(c,'sha256'),'hex'),
    now() + make_interval(hours => ttl),
    10,
    0,
    'active'
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
  if not private.is_verified() then
    raise exception 'EMAIL_NOT_VERIFIED';
  end if;

  if uid is null then
    raise exception 'UNAUTHENTICATED';
  end if;

  select *
  into i
  from public.invitations
  where code_hash = encode(digest(upper(trim(p_code)), 'sha256'), 'hex')
  for update;

  if not found
     or i.status <> 'active'
     or i.expires_at < now()
     or i.redemption_count >= i.max_redemptions then
    raise exception 'INVALID_INVITATION';
  end if;

  h := i.space_id;

  select *
  into m
  from public.space_members
  where space_id = h
    and user_id = uid
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
    insert into public.space_members(space_id, user_id, role)
    values(h, uid, 'member')
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
