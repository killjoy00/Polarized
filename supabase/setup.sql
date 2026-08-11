-- Polarized — full schema. Run once, on a fresh Supabase project.
-- Safe to re-run: everything is if-not-exists / or-replace.
--
-- Table names keep the pol_ prefix even in a dedicated project. The app
-- hardcodes them, and renaming buys nothing.

-- ── tables ────────────────────────────────────────────────────────────

create table if not exists public.pol_rooms (
  code        text primary key,
  round       jsonb,
  created_at  timestamptz not null default now()
);

-- on delete cascade is load-bearing: pol_purge_old_rooms() deletes only
-- rooms, and relies on these to take the players and votes with them.
create table if not exists public.pol_players (
  code    text not null references public.pol_rooms(code) on delete cascade,
  pid     text not null,
  name    text,
  joined  bigint,                      -- Date.now() from the browser
  primary key (code, pid)
);

create table if not exists public.pol_votes (
  code    text not null references public.pol_rooms(code) on delete cascade,
  n       integer not null,            -- round number
  pid     text not null,
  choice  text check (choice in ('a','d')),
  primary key (code, n, pid)
);

create index if not exists pol_rooms_created_at_idx on public.pol_rooms (created_at);

-- ── row level security ────────────────────────────────────────────────
-- Deliberately permissive, matching the behaviour of the shared project so
-- the cutover changes one thing at a time. Hardening is a separate change:
-- votes are readable before the reveal, and any client can write any room.

alter table public.pol_rooms   enable row level security;
alter table public.pol_players enable row level security;
alter table public.pol_votes   enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                 where schemaname='public' and tablename='pol_rooms'
                   and policyname='pol_rooms_all') then
    create policy pol_rooms_all on public.pol_rooms
      for all to anon, authenticated using (true) with check (true);
  end if;

  if not exists (select 1 from pg_policies
                 where schemaname='public' and tablename='pol_players'
                   and policyname='pol_players_all') then
    create policy pol_players_all on public.pol_players
      for all to anon, authenticated using (true) with check (true);
  end if;

  if not exists (select 1 from pg_policies
                 where schemaname='public' and tablename='pol_votes'
                   and policyname='pol_votes_all') then
    create policy pol_votes_all on public.pol_votes
      for all to anon, authenticated using (true) with check (true);
  end if;
end $$;

grant select, insert, update, delete
  on public.pol_rooms, public.pol_players, public.pol_votes
  to anon, authenticated;

-- ── realtime ──────────────────────────────────────────────────────────
-- The app subscribes to all three tables. The 2s poll is the backstop, but
-- without this the lobby only updates every 2 seconds.

do $$
begin
  if not exists (select 1 from pg_publication where pubname='supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

do $$
declare t text;
begin
  foreach t in array array['pol_rooms','pol_players','pol_votes'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename=t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ── cleanup ───────────────────────────────────────────────────────────
-- The privacy policy promises rooms are gone within 24 hours. This is what
-- keeps that true, so it needs the cron schedule below to actually run.

create or replace function public.pol_purge_old_rooms()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.pol_rooms where created_at < now() - interval '24 hours';
$$;

revoke all on function public.pol_purge_old_rooms() from public, anon, authenticated;

-- ── schedule ──────────────────────────────────────────────────────────
-- If this errors, enable pg_cron from Database → Extensions, then re-run.

create extension if not exists pg_cron;

do $$
begin
  if not exists (select 1 from cron.job where jobname='pol-purge-hourly') then
    perform cron.schedule(
      'pol-purge-hourly',
      '17 * * * *',
      $cron$select public.pol_purge_old_rooms()$cron$
    );
  end if;
end $$;
