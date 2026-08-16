-- RLS hardening, part 3 of 3 — identity. Run this LAST, and only after the
-- three checks below all pass. It is the one file here that can lock the whole
-- game out of its own database if applied early.
--
-- What it fixes: until now anyone holding a four-letter room code could write
-- that room's state, overwrite another player's vote, or call pol_reveal()
-- before the room had finished voting. Row level security had nothing to test
-- against, because the browser's identity was a random string it made up.
--
-- What changes: polarized/index.html signs in anonymously on load and uses the
-- resulting auth.uid() as its player id. Every write policy below compares
-- auth.uid() to something already in the row — the moderator named in
-- round->>'modId', or the pid on a player's own row. No login screen, no email,
-- no change the players can see.
--
-- ── before running ────────────────────────────────────────────────────────
--
--  1. Authentication → Sign In / Providers → Anonymous sign-ins: ON.
--     Without it every browser falls back to a local id, auth.uid() is null,
--     and these policies deny every write in the game.
--
--  2. The build that calls signInAnonymously() is live. Load the site, open
--     the console, and confirm there is no "[auth] anonymous sign-in
--     unavailable" warning.
--
--  3. No game is mid-round. Seats taken under the old random ids do not match
--     anyone's auth.uid(); those players are sent back to the home screen and
--     have to rejoin. Rooms purge themselves after 24 hours anyway.
--
-- Rolling back is the block at the bottom of this file.
--
-- ── what this does NOT fix ────────────────────────────────────────────────
--
-- Anyone in a room can still start it while it sits at round null, and the
-- moderator can still write whatever they like into their own round — they own
-- it. Anonymous users also accumulate one auth.users row per browser; they are
-- cheap, but they are not free, and nothing prunes them yet.

begin;

-- Test rooms. tests/*.mjs seeds votes for players that do not exist, which the
-- own-row rules below would otherwise forbid, so the harness gets exactly one
-- exemption: six-character codes beginning ZZ. newCode() in index.html makes
-- four-character codes, so no real room can ever match this.
create or replace function public.pol_is_test_room(c text)
returns boolean
language sql
immutable
as $$ select c ~ '^ZZ.{4}$' $$;

-- ── rooms ─────────────────────────────────────────────────────────────────
-- Reads stay open: the code is the shared secret, as it always was.
-- Updates belong to the moderator of the round that is currently in the row.
-- The check is on the OLD row, deliberately — nextRound() hands the gavel on
-- by writing a new modId, and it has to be allowed to.

drop policy if exists pol_rooms_all on public.pol_rooms;

create policy pol_rooms_read on public.pol_rooms
  for select to anon, authenticated using (true);

create policy pol_rooms_open on public.pol_rooms
  for insert to authenticated with check (true);

create policy pol_rooms_moderate on public.pol_rooms
  for update to authenticated
  using (round is null
         or round->>'modId' = auth.uid()::text
         or public.pol_is_test_room(code))
  with check (true);

create policy pol_rooms_clear on public.pol_rooms
  for delete to authenticated
  using (round->>'modId' = auth.uid()::text or public.pol_is_test_room(code));

-- ── players ───────────────────────────────────────────────────────────────
-- Everyone reads the seating. You write your own seat and nobody else's.
-- Table-level SELECT stays granted, which is what lets the app keep upserting
-- its own player row (INSERT ... ON CONFLICT needs it).

drop policy if exists pol_players_all on public.pol_players;

create policy pol_players_read on public.pol_players
  for select to anon, authenticated using (true);

create policy pol_players_own on public.pol_players
  for insert to authenticated with check (pid = auth.uid()::text);

create policy pol_players_own_update on public.pol_players
  for update to authenticated
  using (pid = auth.uid()::text) with check (pid = auth.uid()::text);

create policy pol_players_own_delete on public.pol_players
  for delete to authenticated using (pid = auth.uid()::text);

-- ── votes ─────────────────────────────────────────────────────────────────
-- rls-2 already took the `choice` column away from browsers. This adds the
-- other half: you can only write the row with your own pid on it. Reading who
-- has voted stays open — that is the "3 of 5 voted" counter.
--
-- Vote writes stay insert-then-update, never upsert. See rls-2 for why; these
-- policies do not change that, and nothing here grants the table-wide SELECT
-- an upsert would need.

drop policy if exists pol_votes_all on public.pol_votes;

create policy pol_votes_read on public.pol_votes
  for select to anon, authenticated using (true);

create policy pol_votes_own on public.pol_votes
  for insert to authenticated
  with check (pid = auth.uid()::text or public.pol_is_test_room(code));

create policy pol_votes_own_update on public.pol_votes
  for update to authenticated
  using (pid = auth.uid()::text or public.pol_is_test_room(code))
  with check (pid = auth.uid()::text or public.pol_is_test_room(code));

commit;

-- ── check it ──────────────────────────────────────────────────────────────
-- As anon, in the SQL editor's "run as" or from a browser with no session:
--   update public.pol_rooms set round = '{}' where code = 'ABCD';
-- Expect 0 rows updated. Then play a full round on the live site — lobby,
-- category, statement, votes, reveal, next round — before walking away.

-- ── roll back ─────────────────────────────────────────────────────────────
-- If the game breaks, this restores the permissive behaviour immediately.
--
--   begin;
--   drop policy if exists pol_rooms_read        on public.pol_rooms;
--   drop policy if exists pol_rooms_open        on public.pol_rooms;
--   drop policy if exists pol_rooms_moderate    on public.pol_rooms;
--   drop policy if exists pol_rooms_clear       on public.pol_rooms;
--   drop policy if exists pol_players_read      on public.pol_players;
--   drop policy if exists pol_players_own       on public.pol_players;
--   drop policy if exists pol_players_own_update on public.pol_players;
--   drop policy if exists pol_players_own_delete on public.pol_players;
--   drop policy if exists pol_votes_read        on public.pol_votes;
--   drop policy if exists pol_votes_own         on public.pol_votes;
--   drop policy if exists pol_votes_own_update  on public.pol_votes;
--   create policy pol_rooms_all   on public.pol_rooms
--     for all to anon, authenticated using (true) with check (true);
--   create policy pol_players_all on public.pol_players
--     for all to anon, authenticated using (true) with check (true);
--   create policy pol_votes_all   on public.pol_votes
--     for all to anon, authenticated using (true) with check (true);
--   commit;
--
-- pol_reveal()'s own moderator check is in rls-1 and is inert without a
-- session, so it needs no rollback of its own.
