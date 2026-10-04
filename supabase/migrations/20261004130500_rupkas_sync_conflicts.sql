
create policy "p_revision_insert" on public.entity_revisions
for insert to authenticated
with check (private.is_member(space_id) and changed_by = (select auth.uid()));

create policy "p_sync_insert" on public.sync_operations
for insert to authenticated
with check ((select auth.uid()) = user_id);

create policy "p_sync_update" on public.sync_operations
for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create or replace function public.sync_transaction_update(
  p_operation_id uuid,
  p_transaction_id uuid,
  p_base_version integer,
  p_type public.tx_type,
  p_amount numeric,
  p_category_id uuid,
  p_transaction_date date,
  p_transaction_time time default null,
  p_note text default null
) returns jsonb
language plpgsql
set search_path to 'public','private'
as $$
declare
  op public.sync_operations;
  current_tx public.transactions;
  updated_tx public.transactions;
begin
  if p_operation_id is null then raise exception 'INVALID_OPERATION_ID'; end if;

  select * into op from public.sync_operations
  where operation_id=p_operation_id and user_id=(select auth.uid());

  if op.id is not null then
    if op.status='applied' then
      select * into current_tx from public.transactions where id=op.entity_id;
      return jsonb_build_object('status','applied','idempotent',true,'transaction',to_jsonb(current_tx));
    elsif op.status='conflict' then
      select * into current_tx from public.transactions where id=op.entity_id;
      return jsonb_build_object('status','conflict','idempotent',true,'transaction',to_jsonb(current_tx));
    end if;
  else
    insert into public.sync_operations(
      user_id,device_id,operation_id,entity_type,entity_id,operation_type,base_version,status,payload
    ) values(
      (select auth.uid()),
      'web',
      p_operation_id,
      'transaction',
      p_transaction_id,
      'update',
      p_base_version,
      'pending',
      jsonb_build_object(
        'type',p_type,'amount',p_amount,'category_id',p_category_id,
        'transaction_date',p_transaction_date,'transaction_time',p_transaction_time,'note',p_note
      )
    ) returning * into op;
  end if;

  begin
    update public.transactions
      set type=p_type,
          amount=p_amount,
          category_id=p_category_id,
          transaction_date=p_transaction_date,
          transaction_time=p_transaction_time,
          note=p_note,
          updated_by=(select auth.uid()),
          updated_at=now(),
          version=version+1
    where id=p_transaction_id
      and version=p_base_version
      and private.is_member(space_id)
    returning * into updated_tx;

    if updated_tx.id is null then
      select * into current_tx from public.transactions where id=p_transaction_id and private.is_member(space_id);
      if current_tx.id is null then
        update public.sync_operations set status='failed',processed_at=now()
        where operation_id=p_operation_id;
        return jsonb_build_object('status','failed','reason','NOT_FOUND_OR_FORBIDDEN');
      end if;

      update public.sync_operations set status='conflict',processed_at=now()
      where operation_id=p_operation_id;

      return jsonb_build_object(
        'status','conflict',
        'base_version',p_base_version,
        'server_version',current_tx.version,
        'transaction',to_jsonb(current_tx)
      );
    end if;

    insert into public.entity_revisions(
      space_id,entity_type,entity_id,version,operation,changed_by,payload
    ) values(
      updated_tx.space_id,'transaction',updated_tx.id,updated_tx.version,'sync_update',
      (select auth.uid()),
      jsonb_build_object('after',to_jsonb(updated_tx),'base_version',p_base_version,'operation_id',p_operation_id)
    );

    update public.sync_operations
      set status='applied',processed_at=now()
    where operation_id=p_operation_id;

    return jsonb_build_object(
      'status','applied',
      'transaction',to_jsonb(updated_tx)
    );
  exception
    when others then
      update public.sync_operations set status='failed',processed_at=now()
      where operation_id=p_operation_id;
      raise;
  end;
end;
$$;
