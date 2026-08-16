-- Run this on the OLD project (euxugjfibsurltcazago), the one foodfinder lives
-- in. Not on the Polarized project.
--
-- Run supabase/inspect-old-project.sql first and read query 3. This script
-- acts on the rule that query explains, and step 2 will not run until you say
-- so — it is the half that touches somebody else's application.

-- ══ step 1 — remove what is ours ════════════════════════════════════════
-- Everything named here was created by this game. It moved to its own project
-- and nothing reads these any more.

begin;

-- unschedule anything of ours in pg_cron, if pg_cron is even installed here
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule(jobid)
      from cron.job
     where command ilike '%pol_purge_old_rooms%';
  end if;
end $$;

drop function if exists public.pol_purge_old_rooms();

drop table if exists public.pol_votes   cascade;
drop table if exists public.pol_players cascade;
drop table if exists public.pol_rooms   cascade;

commit;

-- Confirm nothing of ours is left. Expect zero rows.
select tablename from pg_tables
 where schemaname = 'public' and tablename like 'pol\_%';


-- ══ step 2 — undo what we did to foodfinder's tables ════════════════════
--
-- The old setup script ran `enable row level security` on tables that were
-- never ours, then added permissive `play_%` policies so they still worked.
-- Both halves have to come off, and the order is the whole point:
--
--   disable row level security  →  then  drop policy
--
-- Backwards, there is a window — and after a failure, a permanent state —
-- where RLS is on with no policy that applies, which returns zero rows to
-- every caller and raises no error at all.
--
-- Tables that have policies of their own beside ours are left with RLS
-- enabled; those belong to foodfinder and we only take our policies off them.
--
-- This runs as a rehearsal. It prints what it would do and changes nothing.
-- Read the notices, check them against foodfinder's own migrations, then set
-- v_apply to true and run it again — with the owner present.

do $$
declare
  v_apply  boolean := false;      -- ← flip to true only after reading the plan
  -- named v_ so nothing here shadows a table alias in the queries below;
  -- plpgsql resolves p.policyname to a declared record before it resolves an
  -- alias, and silently breaks the query if one exists
  v_tab    record;
  v_pol    record;
  n_tables integer := 0;
  n_drops  integer := 0;
begin
  for v_tab in
    select c.relname as tbl,
           c.relrowsecurity as rls_on,
           count(*) filter (where p.policyname not like 'play\_%') as others
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      left join pg_policies p on p.schemaname = n.nspname and p.tablename = c.relname
     where n.nspname = 'public'
       and c.relkind = 'r'
       and c.relname not like 'pol\_%'
       and exists (select 1 from pg_policies q
                    where q.schemaname = 'public' and q.tablename = c.relname
                      and q.policyname like 'play\_%')
     group by c.relname, c.relrowsecurity
     order by c.relname
  loop
    n_tables := n_tables + 1;

    if v_tab.others = 0 and v_tab.rls_on then
      raise notice '% : disable row level security (only our policies stand on it)', v_tab.tbl;
      if v_apply then
        execute format('alter table public.%I disable row level security', v_tab.tbl);
      end if;
    elsif v_tab.others > 0 then
      raise notice '% : keep row level security on (% policies of its own)', v_tab.tbl, v_tab.others;
    else
      raise notice '% : row level security already off', v_tab.tbl;
    end if;

    for v_pol in
      select policyname from pg_policies
       where schemaname = 'public' and tablename = v_tab.tbl and policyname like 'play\_%'
       order by policyname
    loop
      n_drops := n_drops + 1;
      raise notice '    drop policy %', v_pol.policyname;
      if v_apply then
        execute format('drop policy if exists %I on public.%I', v_pol.policyname, v_tab.tbl);
      end if;
    end loop;
  end loop;

  raise notice '% table(s), % policy drop(s) — %', n_tables, n_drops,
    case when v_apply then 'APPLIED' else 'rehearsal only, nothing changed' end;
end $$;

-- After applying: have foodfinder's owner load the app and read from every
-- table listed above. An empty list where there used to be rows means RLS is
-- still on somewhere it should not be — `alter table public.<name> disable row
-- level security` fixes it on the spot.
