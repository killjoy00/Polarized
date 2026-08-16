-- RLS hardening, part 2 of 2 — run this LAST, only after the new index.html
-- is deployed. It takes the `choice` column away from browsers, and the old
-- app read that column on every poll: run this while the old build is live
-- and the game breaks.
--
-- Row level security is row-shaped and cannot hide a single column, so this
-- uses column privileges instead. Clients keep reading (code, n, pid) — which
-- is what "3 of 5 voted" counts — and lose `choice` entirely. They still write
-- their own vote, and the reveal comes back through pol_reveal() as part of
-- pol_rooms.round.
--
-- What this does NOT fix: anyone holding a room code can still write that
-- room's state, and can still call pol_reveal early. That needs real identity
-- (anonymous auth) and is deliberately deferred.

revoke select on public.pol_votes from anon, authenticated;

grant select (code, n, pid)         on public.pol_votes to anon, authenticated;
grant insert (code, n, pid, choice) on public.pol_votes to anon, authenticated;
grant update (choice)               on public.pol_votes to anon, authenticated;

-- nothing in the app deletes a vote; rooms cascade theirs away on purge
revoke delete on public.pol_votes from anon, authenticated;

-- Check it: this should fail with a permission error.
--   select choice from public.pol_votes limit 1;   -- as anon
