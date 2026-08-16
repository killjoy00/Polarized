# Polarized

A browser party game. Players join a room from their own phones — over Zoom or
in person. One player moderates: they lock in a category, write a statement,
everyone votes agree or disagree, and the moderator scores one point per
agree/disagree pair they created. Splitting the room evenly is the goal. In a
room of five or more, a sole dissenter takes a bonus point. Default is 2 turns
as moderator each.

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
               *-old-project.sql     ← the debt owed to foodfinder
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
`topic` → `voting` → `reveal`, then `final`. The `topic` phase has two halves:
the moderator locks a category (`round.category`) and then writes the
statement. `round.cats` holds the six categories the room is choosing from and
`round.used` the ones already spent — both are room state, so everyone sees the
same board.

Identity is an anonymous Supabase user. The browser calls `signInAnonymously()`
on load and uses `auth.uid()` as its player id, which is what gives the write
policies something to compare against. If anonymous sign-ins are switched off
the app falls back to a random local id and runs on the permissive policies —
so the client is safe to deploy before the project is switched over, and
`supabase/rls-3-anon-auth.sql` is not.

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
   must agree. `tests/score-parity.mjs` checks that. Changing a scoring rule
   means editing both and re-running `supabase/rls-1-reveal-function.sql`
   against the project — it is `create or replace`, so re-running is the
   migration.

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
- a lone dissenter (1 vs 2+) scores +1; the moderator never takes this, and it
  only exists at five seats or more. Seats at the table, not votes cast: in a
  three- or four-player room standing alone is a coin flip rather than a stand,
  and the bonus starts outweighing the pairs it costs the moderator. The
  threshold is `WOLF_MIN_SEATS` in `index.html` and a literal `5` in
  `pol_reveal()`.

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
speaking them. The writing phase now offers dictation — a "Speak it instead"
button on the moderator's textarea, backed by the Web Speech API. It is
feature-detected: Chrome, Edge and Safari (iOS included) have it, Firefox does
not, and there the button is simply not drawn. If the rhythm is still slow, the
intended fix is a countdown on the writing phase, not a structural change.

The reveal screen is the product. Everything else is plumbing. Leftover players
are drawn there as empty boxes on their own side, the same size as the filled
ones a pair gets — they are the people nobody was found to cancel out, and the
screen says that by drawing it rather than labelling it.

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
- Category lock-in, shared categories, standings while you wait, dictation, the
  leftover boxes on the reveal — played through end to end in five browsers
  against the live project

**Written, waiting on the project owner**

Two things below need a hand on the Supabase dashboard. Neither is in the repo's
gift, and both are in order.

- **Re-run [`supabase/rls-1-reveal-function.sql`](supabase/rls-1-reveal-function.sql).**
  `pol_reveal()` in the live project still pays the lone wolf in a four-player
  room, and still lets any caller reveal. Until it is re-run, both test suites
  fail on purpose and say which file to run. Verified against a local
  PostgreSQL 16 with the schema loaded: 400 generated rounds, no disagreement
  with `score()`.
- **Identity.** [`supabase/rls-3-anon-auth.sql`](supabase/rls-3-anon-auth.sql)
  closes the write hole: room state becomes writable only by the moderator
  named in `round->>'modId'`, a player row only by its owner, a vote only by
  the player casting it. The order is: this build goes live (it signs in
  anonymously and falls back cleanly), then Authentication → Sign In /
  Providers → **Anonymous sign-ins: on**, then run the file. Confirmed disabled
  on the project as of this writing — `/auth/v1/signup` answers
  `anonymous_provider_disabled`. Every policy was exercised locally: the
  moderator's whole write path passes, a non-moderator gets zero rows, and the
  insert-then-update vote path still works while an upsert still fails, so
  invariant 4 survives. Rollback is at the bottom of the file.

**Open**
- **Keep-alive.** `.github/workflows/keepalive.yml` pings daily. GitHub disables
  scheduled workflows in repos idle 60 days; a Cloudflare Worker cron has no
  such rule if that ever bites.
- **The old shared project** (`euxugjfibsurltcazago`) still runs, still holds
  the old `pol_` tables and stale rooms, and still carries `play_%` policy
  residue on foodfinder's tables from the original collision. Cleaning it means
  editing a database that runs someone else's app, so it is now two files.
  [`inspect-old-project.sql`](supabase/inspect-old-project.sql) is read-only and
  answers the one question that matters: which of foodfinder's tables have RLS
  standing on nothing but a policy we added. [`cleanup-old-project.sql`](supabase/cleanup-old-project.sql)
  drops our objects, then rehearses the repair — printing every table and policy
  it would touch and changing nothing until `v_apply` is set to true. The order
  it uses is the whole point: **disable RLS first, then drop the policy.**
  Backwards leaves a table with RLS on and no policy that applies, which returns
  zero rows to everyone and raises no error. Both scripts were run against a
  simulated copy of the collision locally — three tables, one of them with a
  policy of its own — and foodfinder's reads survived. Still do it with the
  owner present.
- **Anonymous users accumulate.** One `auth.users` row per browser, and nothing
  prunes them.

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

The SQL does not need Supabase to be checked. A local PostgreSQL 16 with two
stand-ins — roles `anon` and `authenticated`, and an `auth.uid()` reading
`request.jwt.claim.sub` — takes `setup.sql` and all three `rls-*.sql` files as
they are, which is how the scoring change and every policy in `rls-3` were
verified before anyone touched the live project. `set role authenticated; set
request.jwt.claim.sub = '<uuid>';` is enough to play a policy through.
