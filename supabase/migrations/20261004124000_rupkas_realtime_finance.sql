do $$
declare t text;
begin
  foreach t in array array['debts','debt_payments','savings_goals','savings_movements','fixed_bills','bill_occurrences','bill_payments'] loop
    if not exists (
      select 1 from pg_publication_rel r
      join pg_class c on c.oid=r.prrelid
      join pg_namespace n on n.oid=c.relnamespace
      where r.prpubid=(select oid from pg_publication where pubname='supabase_realtime')
        and n.nspname='public' and c.relname=t
    ) then
      execute format('alter publication supabase_realtime add table public.%I',t);
    end if;
  end loop;
end $$;