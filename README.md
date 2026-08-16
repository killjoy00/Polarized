# Polarized

A browser party game. Players join a room from their own phones — over Zoom or
in person. One player moderates: they type a statement, everyone votes agree or
disagree, and the moderator scores one point per agree/disagree pair they
created. Splitting the room evenly is the goal. A sole dissenter takes a bonus
point. Default is 2 turns as moderator each.

Live at <https://polarized.planitnow.us>.

Digital rework of a published board game (Agree to Disagree,
[BGG 388659](https://boardgamegeek.com/boardgame/388659)). The physical edition
hides votes with plastic devices; that mechanic is deliberately removed, since
separate phones make hidden voting free.

## Stack

One static `index.html`. No build step, no framework, no bundler. Vanilla JS
rendering template literals into a single `#app` div. Supabase from CDN.
~650 lines including CSS. Served by a git-connected Cloudflare Worker: a push
to `main` deploys `polarized/` as static assets, no build step involved.

```
polarized/     index.html, ads.txt   ← the deployed site root
  privacy/     index.html          ← served at /privacy
supabase/      setup.sql             ← run once on a fresh project
               rls-*.sql             ← hardening, run in order
tests/         *.mjs                 ← scoring parity, run with node
README.md
.gitignore
```

## Backend

Supabase project `hqvqxwlgjjxufbjklfhj`, dedicated to Polarized. Schema lives
in [`supabase/setup.sql`](supabase/setup.sql) — run it once on a fresh project
and everything the app needs exists.

Tables keep the `pol_` prefix. It's no longer load-bearing now that the project
is Polarized's alone, but the app hardcodes the names and renaming buys
nothing. The prefix exists because an earlier version ran in a project shared
with an unrelated app called foodfinder, used bare names (`rooms`, `players`,
`votes`), collided with foodfinder's existing `votes` table, broke it, and
applied permissive RLS policies to a table that wasn't ours. That project
(`euxugjfibsurltcazago`) still holds the old `pol_` tables and the policy
residue; neither is this project's problem, but the cleanup is still owed to
foodfinder's owner.

**This project sleeps after ~7 days idle** — free tier. The shared project
never did, because foodfinder's traffic kept it warm. Something has to ping
this one or the game is dead after a quiet fortnight.

| table | columns | primary key |
| --- | --- | --- |
| `pol_rooms` | `code`, `round` (jsonb), `created_at` | `code` |
| `pol_players` | `code`, `pid`, `name`, `joined` | `(code, pid)` |
| `pol_votes` | `code`, `n`, `pid`, `choice` | `(code, n, pid)` |

All game state for a room lives in `pol_rooms.round` as JSON. Phases run
`topic` → `voting` → `reveal`, then `final`.

`public.pol_purge_old_rooms()` deletes rooms older than 24 hours, scheduled
hourly with `pg_cron`. It deletes rooms only — the foreign keys cascade, so
players and votes go with them. Verified against the live project by deleting a
test room and confirming both child tables emptied.

Clients can read `(code, n, pid)` from `pol_votes` but **not `choice`** — that
is a column-level grant, since row level security cannot hide a column. So a
browser can see who has voted and never what they picked. Choices come back
only in `round.revealed`, written by `pol_reveal()` when the moderator reveals.

## Invariants — do not break these

1. **Each player writes only their own `pol_players` and `pol_votes` row. Only
   the moderator writes `pol_rooms.round`.** This is what makes simultaneous
   joins safe. Preserve it.

2. **Sync is Supabase Realtime plus a 2-second polling backstop.** Realtime was
   unreliable in development; polling is what actually made the lobby work. Do
   not remove the poll without verifying realtime end to end on real devices
   first.

3. **`render()` compares a JSON signature of state and returns early when
   nothing changed, and saves/restores focus and cursor position when it does
   repaint.** Without this the poll wipes the moderator's textarea
   mid-sentence. Any change to the render path must preserve both behaviors.

4. **Votes are written with insert-then-update, never upsert.** Browsers have
   no table-wide `SELECT` on `pol_votes`, and Postgres demands one for
   `INSERT ... ON CONFLICT DO UPDATE` — an upsert fails with `42501` even
   though every column it touches is granted. Collapsing this back into an
   `.upsert()` breaks voting outright.

5. **Scoring lives in `pol_reveal()`, not the browser.** `score()` in
   `index.html` still draws the reveal screen from `round.revealed`, so the two
   must agree. `tests/score-parity.mjs` checks that.

## Config

At the top of `polarized/index.html`:

- `SB_URL`, `SB_KEY` — Supabase project URL and publishable key. The
  publishable key is public by design and safe to commit. **A `service_role`
  key must never enter this repo.**
- `AD_CLIENT` — set. `AD_SLOT` — empty, because the AdSense account is still in
  review. Ads render only on the lobby and final-score screens, never
  mid-round.

## Scoring

Per round, counting only players who voted (the moderator's own vote is
excluded unless `modCounts` is on):

- moderator scores `min(agree, disagree)` — one point per pair
- a lone dissenter (1 vs 2+) scores +1; the moderator never takes this

Scoring runs in the database, in `pol_reveal()`. `score()` in `index.html` is
kept in step because the reveal screen redraws pairs from `round.revealed`.
`tests/score-parity.mjs` checks the two agree across generated rounds — run it
after touching either.

## Gameplay is settled

Extensively playtested. Do not add mechanics unprompted. Already considered and
explicitly rejected:

- a moderator "called shot" predicting who dissents
- a general minority-vote bonus — it rewards guessing the contrarian side
  instead of answering honestly; the sole-dissenter restriction is the whole
  point
- counting the moderator's vote toward pairs by default — it's an option, off
  by default

Open question from playtesting: typing statements may slow the rhythm versus
speaking them. If that shows up, the intended fix is a countdown on the writing
phase, not a structural change.

The reveal screen is the product. Everything else is plumbing.

## Open work

Status as of the move to a dedicated Supabase project.

**Done and verified**
- Repo, README, privacy policy, `.gitignore`
- Dedicated Supabase project, schema in `supabase/setup.sql`
- Purge scheduled hourly with `pg_cron` — confirmed by observing test rooms
  disappear, not just by the job row existing
- Realtime confirmed working under the app's exact subscription pattern
- Deployed and playtested with three players
- Pre-reveal vote leak closed: scoring moved into `pol_reveal()`, `choice`
  revoked from browsers, own vote kept in local storage
- Git deploys: a Cloudflare Worker builds `polarized/` from `main` on push

**Open**
- **Anyone with a room code can still write that room's state**, and can call
  `pol_reveal` early. Vandalism rather than cheating, and it needs a code you
  were told. The only real fix is anonymous auth, so a policy can compare
  `auth.uid()` to `round->>'modId'` — which drags in identity changes, realtime
  JWTs and an `auth.users` row per browser. Deferred until the link is public.
- **Keep-alive.** `.github/workflows/keepalive.yml` pings daily. GitHub disables
  scheduled workflows in repos idle 60 days; a Cloudflare Worker cron has no
  such rule if that ever bites.
- **The old shared project** (`euxugjfibsurltcazago`) still runs, still holds
  the old `pol_` tables and stale rooms, and still carries `play_%` policy
  residue on foodfinder's tables from the original collision. Cleaning it means
  editing a database that runs someone else's app — inspect first, and do it
  with that owner present.

**Worth knowing**

The first realtime subscription to a fresh project delivered nothing; five
subsequent runs of the identical pattern all worked. Best explanation is a
cold-start race while the realtime tenant provisions — unproven. The same
condition may recur on the first connection after the project has been idle,
which is precisely what the 2-second poll covers.

## Local development

No server needed for the markup, but the Supabase client needs a real origin:

```sh
python3 -m http.server 8000 --directory polarized
```

Then open <http://localhost:8000>. It talks to the live Supabase project, so
use a throwaway room code.
