-- Bind each Family invitation to the intended recipient email.
-- Store only a SHA-256 hash of the normalized email.

alter table public.invitations
  add column if not exists recipient_email_hash text;

create or replace function public.create_invitation(
  p_space_id uuid,
  p_recipient_email text,
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
  recipient text := lower(trim(coalesce(p_recipient_email, '')));
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

  if recipient = '' or position('@' in recipient) < 2 then
    raise exception 'INVALID_RECIPIENT_EMAIL';
  end if;

  ttl := greatest(1, least(coalesce(p_ttl_hours, 168), 168));

  update public.invitations
  set status = 'revoked'
  where space_id = p_space_id
    and status = 'active';

  c := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

  insert into public.invitations(
    space_id, created_by, code_hash, recipient_email_hash, expires_at,
    max_redemptions, redemption_count, status
  )
  values(
    p_space_id,
    (select auth.uid()),
    encode(extensions.digest(c, 'sha256'), 'hex'),
    encode(extensions.digest(recipient, 'sha256'), 'hex'),
    now() + make_interval(hours => ttl),
    10, 0, 'active'
  );

  return c;
end;
$$;

revoke all on function public.create_invitation(uuid, integer) from public;
revoke all on function public.create_invitation(uuid, integer) from authenticated;
revoke all on function public.create_invitation(uuid, text, integer) from public;
grant execute on function public.create_invitation(uuid, text, integer) to authenticated;

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
  current_email text;
begin
  if uid is null then
    raise exception 'UNAUTHENTICATED';
  end if;

  select lower(trim(u.email))
  into current_email
  from auth.users u
  where u.id = uid
    and u.email_confirmed_at is not null;

  if current_email is null then
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

  if i.recipient_email_hash is not null
     and i.recipient_email_hash <> encode(extensions.digest(current_email, 'sha256'), 'hex') then
    raise exception 'INVITATION_EMAIL_MISMATCH';
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
