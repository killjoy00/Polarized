-- Run this on the OLD project (euxugjfibsurltcazago), the one foodfinder lives
-- in. Not on the Polarized project.
--
-- This used to infer what to do from the shape of the database. It does not any
-- more: inspect-old-project.sql was run against the real thing, and the answer
-- it gave was different from what the inference predicted, in two ways worth
-- writing down.
--
-- ── what is actually there ────────────────────────────────────────────────
--
-- Five tables are the old game's, in two generations. The bare-named ones came
-- first and are what caused the collision; the pol_ ones replaced them:
--
--     rooms, players            (code/round/created_at, code/pid/name/joined)
--     pol_rooms, pol_players, pol_votes
--
-- foodfinder's `votes` table was never ours and was never altered by us — its
-- columns are session_id, profile_id, pick_id, veto_id, deferred, with no game
-- columns among them. The old script simply pointed at the name, failed, and
-- left three permissive policies behind on somebody else's table.
--
-- ── the first correction ──────────────────────────────────────────────────
--
-- Every one of foodfinder's twelve other tables has row level security ON and
-- NO policies at all. That combination returns zero rows to anon — measured,
-- not assumed: anon reads 0 from restaurants and 0 from ratings. foodfinder
-- therefore does not reach its data through the anon key; it uses service_role
-- or a direct connection, both of which bypass RLS entirely.
--
-- So the ordering rule the earlier version of this file was built around —
-- disable RLS first, then drop the policy — does not apply here. There is no
-- table whose RLS we need to undo, because RLS being on is foodfinder's own
-- normal state and nothing it does depends on a policy.
--
-- ── the second correction, and the reason this is worth doing ─────────────
--
-- `votes` is the single foodfinder table that anon CAN read: 40 of 40 rows,
-- through our leftover play_read. play_write and play_update let anon insert
-- and modify rows there too. Every sibling table is closed and that one is
-- open, because of us.
--
-- Dropping those three policies closes it and leaves `votes` exactly like its
-- twelve siblings. Disabling RLS on it — which is what the inference rule
-- would have done, seeing no other policies — would have done the opposite and
-- left it open for good.

begin;

-- ── 1. what is about to happen ────────────────────────────────────────────
-- Read this before the commit. Expect five tables and three policies.

select 'drop table' as action, tablename as object
  from pg_tables
 where schemaname = 'public'
   and tablename in ('rooms','players','pol_rooms','pol_players','pol_votes')
union all
select 'drop policy', policyname || ' on ' || tablename
  from pg_policies
 where schemaname = 'public' and policyname like 'play\_%'
 order by 1 desc, 2;

-- Nothing of foodfinder's should point at a table we are dropping. Expect
-- zero rows; if this returns anything, roll back and send it on.

select conrelid::regclass as from_table, conname, confrelid::regclass as points_at
  from pg_constraint
 where contype = 'f'
   and confrelid::regclass::text in ('rooms','players','pol_rooms','pol_players','pol_votes')
   and conrelid::regclass::text not in ('rooms','players','pol_rooms','pol_players','pol_votes');

-- ── 2. remove the old game ────────────────────────────────────────────────
-- Both generations. Their policies and grants go with the tables.

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
drop table if exists public.players     cascade;
drop table if exists public.rooms       cascade;

-- ── 3. close the hole on foodfinder's votes table ─────────────────────────
-- Policies only. RLS stays exactly as it is, which is how every other table
-- in this database is configured.

drop policy if exists play_read   on public.votes;
drop policy if exists play_update on public.votes;
drop policy if exists play_write  on public.votes;

commit;

-- ── 4. check it ───────────────────────────────────────────────────────────

-- Nothing of ours left: expect zero rows.
select tablename from pg_tables
 where schemaname = 'public'
   and (tablename like 'pol\_%' or tablename in ('rooms','players'));

select policyname, tablename from pg_policies
 where schemaname = 'public' and policyname like 'play\_%';

-- votes now answers anon the way its siblings do: expect 0 and 0.
--
-- `set role`, not `set local role` — the latter is a no-op outside a
-- transaction and quietly leaves you running as the owner, who bypasses RLS
-- and reports every row as though nothing had changed. This check is only
-- worth running if it can fail.
set role anon;
select (select count(*) from public.votes)       as votes_to_anon,
       (select count(*) from public.restaurants) as restaurants_to_anon;
reset role;

-- And foodfinder itself is untouched: as the owner, the rows are all still
-- there. If this shows fewer votes than you had, something is very wrong and
-- the undo from inspect-old-project.sql query 5 is what you want.
select count(*) as votes_rows from public.votes;

-- Then open foodfinder and run a vote session end to end. RLS never applied to
-- it, so nothing here should change what it can do — but the room purge on the
-- Polarized project was verified by watching rooms disappear rather than by
-- trusting the job row, and the same standard applies to somebody else's app.
