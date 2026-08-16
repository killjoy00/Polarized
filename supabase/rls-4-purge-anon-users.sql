-- Prune anonymous users. Run on the Polarized project, after rls-3.
--
-- Anonymous sign-in gives every browser an auth.users row, and nothing takes
-- it away again. Rooms purge after 24 hours; the identities that played in
-- them do not. This is the other half of that housekeeping.
--
-- Deleting an anonymous user costs the player nothing. Their next visit finds
-- a dead refresh token, signs in again, and gets a new id — invisible, because
-- the room they were in is long gone and their name lives in local storage,
-- not in auth. index.html already treats a seat whose id no longer matches as
-- somebody else's seat.
--
-- The window below is deliberately much longer than it needs to be. What it is
-- really protecting against is deleting somebody mid-game, which is why the
-- query looks at their sessions and not just at when they signed in: a browser
-- that plays every week may not have signed in since the first time.

-- ── 1. look first ─────────────────────────────────────────────────────────
--
-- `is_anonymous` and `auth.sessions` both arrived with anonymous sign-ins, so
-- they exist on any project that can create the users this deletes — but this
-- reads the auth schema, which is Supabase's, not ours, and it does move.
-- Run this before creating anything. It answers three questions: do the
-- columns exist, how many users are there, and how many would go.

select count(*)                                        as anon_users,
       count(*) filter (where u.created_at > now() - interval '24 hours') as made_today,
       min(u.created_at)                               as oldest,
       count(*) filter (where greatest(
           u.created_at,
           coalesce(u.last_sign_in_at, u.created_at),
           coalesce(u.updated_at,      u.created_at),
           coalesce((select max(greatest(s.created_at, s.updated_at))
                       from auth.sessions s where s.user_id = u.id), u.created_at)
         ) < now() - interval '7 days')                as would_delete
  from auth.users u
 where u.is_anonymous;

-- ── 2. the function ───────────────────────────────────────────────────────
--
-- security definer, because anon and authenticated have no business in the
-- auth schema — and it is revoked from them below regardless. Deleting from
-- auth.users cascades to identities, sessions and refresh tokens.
--
-- `where u.is_anonymous` is the guard that matters. If this game ever grows
-- real accounts, this function must not be able to touch one.

create or replace function public.pol_purge_anon_users(p_age interval default '7 days')
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted integer;
begin
  with stale as (
    select u.id
      from auth.users u
     where u.is_anonymous
       and greatest(
             u.created_at,
             coalesce(u.last_sign_in_at, u.created_at),
             coalesce(u.updated_at,      u.created_at),
             coalesce((select max(greatest(s.created_at, s.updated_at))
                         from auth.sessions s where s.user_id = u.id), u.created_at)
           ) < now() - p_age
  )
  delete from auth.users u using stale where u.id = stale.id;

  get diagnostics v_deleted = row_count;
  return v_deleted;
end $$;

revoke all on function public.pol_purge_anon_users(interval) from public, anon, authenticated;

-- ── 3. schedule it ────────────────────────────────────────────────────────
-- Daily, at an odd minute, well away from the hourly room purge.

do $$
begin
  if not exists (select 1 from cron.job where jobname='pol-purge-anon-users-daily') then
    perform cron.schedule(
      'pol-purge-anon-users-daily',
      '43 3 * * *',
      $cron$select public.pol_purge_anon_users()$cron$
    );
  end if;
end $$;

-- ── 4. check it ───────────────────────────────────────────────────────────
--
-- Run it once by hand with a window nothing can possibly fall inside, and
-- confirm it returns 0 rather than an error — that proves the permissions and
-- the auth-schema references, without deleting anybody. Make the window
-- absurd, not merely large; the comparison is `<`, so a user of exactly the
-- age you name is old enough:
--
--   select public.pol_purge_anon_users('100 years');
--
-- Then let the schedule take it from there. To confirm the job is really
-- running, rather than merely scheduled:
--
--   select jobname, status, return_message, start_time
--     from cron.job_run_details
--    where jobname = 'pol-purge-anon-users-daily'
--    order by start_time desc limit 5;
--
-- The room purge was verified by watching rooms disappear, not by trusting the
-- job row. Same standard applies here.
