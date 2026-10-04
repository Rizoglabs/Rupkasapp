-- Allow authenticated members to use the existing invoker RPCs for financial writes.
-- Authorization remains space-membership based; creator-owned rows cannot be reassigned.

create policy p_budget_insert on public.budgets
  for insert to authenticated
  with check (private.is_member(space_id));
create policy p_budget_update on public.budgets
  for update to authenticated
  using (private.is_member(space_id))
  with check (private.is_member(space_id));
create policy p_budget_delete on public.budgets
  for delete to authenticated
  using (private.is_member(space_id));

create policy p_debt_insert on public.debts
  for insert to authenticated
  with check (private.is_member(space_id) and created_by = (select auth.uid()));
create policy p_debt_update on public.debts
  for update to authenticated
  using (private.is_member(space_id))
  with check (private.is_member(space_id) and created_by = (select auth.uid()));
create policy p_debt_delete on public.debts
  for delete to authenticated
  using (private.is_member(space_id));

create policy p_fixed_bill_insert on public.fixed_bills
  for insert to authenticated
  with check (private.is_member(space_id) and created_by = (select auth.uid()));
create policy p_fixed_bill_update on public.fixed_bills
  for update to authenticated
  using (private.is_member(space_id))
  with check (private.is_member(space_id) and created_by = (select auth.uid()));
create policy p_fixed_bill_delete on public.fixed_bills
  for delete to authenticated
  using (private.is_member(space_id));

create policy p_savings_goal_insert on public.savings_goals
  for insert to authenticated
  with check (private.is_member(space_id) and created_by = (select auth.uid()));
create policy p_savings_goal_update on public.savings_goals
  for update to authenticated
  using (private.is_member(space_id))
  with check (private.is_member(space_id) and created_by = (select auth.uid()));
create policy p_savings_goal_delete on public.savings_goals
  for delete to authenticated
  using (private.is_member(space_id));

create policy p_savings_movement_insert on public.savings_movements
  for insert to authenticated
  with check (
    (select auth.uid()) = created_by
    and exists (
      select 1 from public.savings_goals g
      where g.id = goal_id and private.is_member(g.space_id)
    )
  );

create policy p_bill_occurrence_insert on public.bill_occurrences
  for insert to authenticated
  with check (
    exists (
      select 1 from public.fixed_bills b
      where b.id = fixed_bill_id and private.is_member(b.space_id)
    )
  );
create policy p_bill_occurrence_update on public.bill_occurrences
  for update to authenticated
  using (
    exists (
      select 1 from public.fixed_bills b
      where b.id = fixed_bill_id and private.is_member(b.space_id)
    )
  )
  with check (
    exists (
      select 1 from public.fixed_bills b
      where b.id = fixed_bill_id and private.is_member(b.space_id)
    )
  );
create policy p_bill_occurrence_delete on public.bill_occurrences
  for delete to authenticated
  using (
    exists (
      select 1 from public.fixed_bills b
      where b.id = fixed_bill_id and private.is_member(b.space_id)
    )
  );

create policy p_transaction_insert on public.transactions
  for insert to authenticated
  with check (
    private.is_member(space_id)
    and created_by = (select auth.uid())
    and updated_by = (select auth.uid())
  );
create policy p_transaction_update on public.transactions
  for update to authenticated
  using (private.is_member(space_id))
  with check (
    private.is_member(space_id)
    and updated_by = (select auth.uid())
  );
create policy p_transaction_delete on public.transactions
  for delete to authenticated
  using (private.is_member(space_id));
