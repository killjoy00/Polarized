-- Run this on the OLD project (euxugjfibsurltcazago), the one foodfinder lives
-- in. Not on the Polarized project.
--
-- Removes only objects Polarized created. Everything named here is ours: the
-- game moved to its own project and nothing reads these any more.
--
-- It deliberately does NOT touch the play_% policies left on foodfinder's own
-- tables by the original setup script. That script also ran "enable row level
-- security" on those tables, so dropping a permissive policy can turn a
-- working read into an empty result. Inspect, then decide, with foodfinder in
-- front of you. The query at the bottom is the inspection.

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

-- SEPARATE QUESTION — do not act on this yet. Send the output back.
-- These are the policies the old setup script put on tables that were never
-- ours. Which tables they sit on decides whether dropping them is safe.
select tablename, policyname, cmd, roles
  from pg_policies
 where schemaname = 'public' and policyname like 'play\_%'
 order by tablename, policyname;
