drop index if exists public.bill_occurrences_fixed_bill_period_uq;
create index if not exists bill_payments_transaction_id_idx on public.bill_payments(transaction_id);
create index if not exists debt_payments_transaction_id_idx on public.debt_payments(transaction_id);
create index if not exists debts_created_by_idx on public.debts(created_by);
create index if not exists savings_goals_created_by_idx on public.savings_goals(created_by);