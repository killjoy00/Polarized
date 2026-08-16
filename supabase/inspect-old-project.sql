-- Read-only. Run this on the OLD project (euxugjfibsurltcazago), the one
-- foodfinder lives in. Nothing here changes anything.
--
-- Background: an early version of this game ran in foodfinder's project, used
-- bare table names, and its setup script ran `enable row level security` on
-- tables that were never ours before adding permissive `play_%` policies to
-- keep them readable. Enabling RLS is the dangerous half. A table with RLS on
-- and no policy that applies returns zero rows to everyone — silently, with no
-- error — so dropping our policies without first undoing the enable would
-- break foodfinder in the most confusing way available.
--
-- Run all five queries. Their output is what cleanup-old-project.sql needs in
-- order to be safe. Query 5 prints your undo — save it before dropping
-- anything.

-- 1. Ours. Everything here can be dropped; nothing reads it any more.
select tablename
  from pg_tables
 where schemaname = 'public' and tablename like 'pol\_%'
 order by tablename;

-- 2. The policies our old setup left on tables that were never ours.
select tablename, policyname, cmd, roles, qual, with_check
  from pg_policies
 where schemaname = 'public' and policyname like 'play\_%'
 order by tablename, policyname;

-- 3. The decision table. For every table carrying a play_% policy:
--
--    other_policies = 0  →  the only thing standing between foodfinder and an
--                           empty result is a policy we added. That table was
--                           almost certainly not using RLS before we arrived,
--                           and the repair is to turn RLS back off BEFORE
--                           dropping the policy.
--
--    other_policies > 0  →  the table has its own RLS regime. Leave RLS
--                           enabled and drop only the play_% policies.
--
-- Check this against foodfinder's own migrations before acting: the query
-- infers intent from the current state, and cannot tell a table you meant to
-- protect from one we enabled RLS on by accident.
--
-- The question that settles it fastest is how foodfinder reaches its database.
-- If it goes through a service_role key or a direct Postgres connection, RLS
-- never applied to it in the first place and none of this can break it. Only a
-- browser holding the anon key is exposed to any of these policies.
select c.relname                                     as tablename,
       c.relrowsecurity                              as rls_enabled,
       count(*) filter (where p.policyname like 'play\_%')     as play_policies,
       count(*) filter (where p.policyname not like 'play\_%') as other_policies
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
 order by other_policies, c.relname;

-- 4. Anything of ours still scheduled. Prints nothing if pg_cron was never
--    installed here, which is a valid answer and not an error.
do $$
declare v_job record;
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed on this project — nothing of ours is scheduled';
    return;
  end if;
  for v_job in execute
    $q$ select jobid, jobname, schedule, command from cron.job where command ilike '%pol\_%' $q$
  loop
    raise notice 'job % (%) % : %', v_job.jobid, v_job.jobname, v_job.schedule, v_job.command;
  end loop;
end $$;

-- 5. Your undo. This writes nothing — it prints the SQL that would put every
--    play_% policy back exactly as it stands right now, RLS included.
--
--    Save the output somewhere before running cleanup-old-project.sql with
--    v_apply on. It is the only record of these policies once they are
--    dropped, and it restores them verbatim: round-tripped against a
--    simulated copy of the collision, dropped and recreated, and the resulting
--    state compared and found identical.
select string_agg(stmt, E'\n' order by tablename, policyname) as undo_script from (
  select p.tablename, p.policyname,
         format('alter table public.%I enable row level security;', p.tablename) ||
         E'\n' ||
         format('create policy %I on public.%I for %s to %s%s%s;',
                p.policyname, p.tablename,
                case p.cmd when 'ALL' then 'all' else lower(p.cmd) end,
                array_to_string(p.roles, ', '),
                coalesce(' using (' || p.qual || ')', ''),
                coalesce(' with check (' || p.with_check || ')', '')) as stmt
    from pg_policies p
   where p.schemaname = 'public' and p.policyname like 'play\_%'
) g;
