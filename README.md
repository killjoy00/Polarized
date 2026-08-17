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
~970 lines including CSS. Served by a git-connected Cloudflare Worker: a push
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
with another app called foodfinder, used bare names (`rooms`, `players`,
`votes`), collided with foodfinder's existing `votes` table, and applied
permissive RLS policies to a table that wasn't ours. That project
(`euxugjfibsurltcazago`) has since been cleaned up — see the bottom of this
file. The collision damaged no data: foodfinder's `votes` was never altered,
only wrapped in policies that left it readable and writable by anyone holding
that project's anon key.

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

`round.order` is the seating. It is built at `startGame()` and can still grow:
`nextRound()` reconciles it against `pol_players` and seats anyone who arrived
late, at the end, in join order. That happens in `nextRound()` and nowhere else
because only the moderator may write `round`. A newcomer waits out the round in
progress — they are shown the standings and offered no vote, since a vote from
an unseated player is stored and never scored. Seating them lengthens the game,
which is `seats × laps`; the one exception is the final round, where a late
arrival is not seated at all rather than extending a game that was ending.

Identity is an anonymous Supabase user. The browser calls `signInAnonymously()`
on load and uses `auth.uid()` as its player id, which is what gives the write
policies something to compare against.

Since those policies are applied, a browser without a session cannot write
anything — so a failed sign-in disables the home screen and says so, rather
than letting someone join a room and save nothing. It retries once on its own
and offers a button for the third go. The same path catches a returning player
whose user has been pruned: dead refresh token, empty session, sign in again as
somebody new.

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
   first. Because both call `refresh()`, several can be in flight at once —
   `refreshSeq` drops any reply that a newer one has already overtaken. Without
   it a slow reply lands last and drags the screen back to the previous round.

3. **`render()` compares a JSON signature of state and returns early when
   nothing changed, and saves/restores focus and cursor position when it does
   repaint.** Without this the poll wipes the moderator's textarea
   mid-sentence. Any change to the render path must preserve both behaviors.

4. **Votes are written with insert-then-update, never upsert.** Browsers have
   no table-wide `SELECT` on `pol_votes`, and Postgres demands one for
   `INSERT ... ON CONFLICT DO UPDATE` — an upsert fails with `42501` even
   though every column it touches is granted. Collapsing this back into an
   `.upsert()` breaks voting outright. Both writes are error-checked and the
   screen rolls back if they fail: nobody can read `choice` back, so a lost
   vote is otherwise invisible to the player who cast it.

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

**Applied to the live project**

- **Scoring.** [`rls-1-reveal-function.sql`](supabase/rls-1-reveal-function.sql)
  re-run: the lone wolf needs five seats, and only the moderator can reveal.
- **Identity.** Anonymous sign-ins are on, and
  [`rls-3-anon-auth.sql`](supabase/rls-3-anon-auth.sql) is applied. Room state
  is writable only by the moderator named in `round->>'modId'`, a player row
  only by its owner, a vote only by the player casting it. A client with no
  session gets `42501` on every write.

  Confirmed against the live project, not just locally: both suites green
  (120 generated rounds with no disagreement with `score()`, 52 of them under
  five seats; all nine edge cases including a non-moderator being refused a
  reveal), and a five-player game played through five signed-in browsers —
  which is the part the suites cannot reach, since they seed votes through the
  `ZZ` test-room exemption rather than as the player casting them.

  The rollback is still at the bottom of rls-3 if the policies ever need
  lifting in a hurry.

- **Anonymous users.** [`rls-4-purge-anon-users.sql`](supabase/rls-4-purge-anon-users.sql)
  is applied. `pol_purge_anon_users()` runs daily at 03:43 UTC under `pg_cron`,
  deleting anonymous users idle for seven days. Deleting one costs the player
  nothing — their next visit finds a dead refresh token and signs in again —
  but it must never delete somebody mid-game, which is why staleness looks at
  their sessions and not only at when they last signed in.

  The smoke test (`pol_purge_anon_users('100 years')`) returned 0, which is what
  proves the permissions and the auth-schema references without deleting
  anybody, and the job is registered and active. It has not fired yet: watch
  `cron.job_run_details` rather than the job row, the same way the room purge
  was confirmed.

**The old shared project** (`euxugjfibsurltcazago`)

[`cleanup-old-project.sql`](supabase/cleanup-old-project.sql) has been run.
Five tables of the old game's are gone, in two generations — bare-named `rooms`
and `players` from before the prefix existed, then `pol_rooms`, `pol_players`
and `pol_votes` — and the three `play_%` policies are off foodfinder's `votes`.

**The residue was a hole, not clutter.** Every one of foodfinder's twelve other
tables has RLS on and no policies, which returns nothing to `anon`, so
foodfinder reaches its data as `service_role` or over a direct connection.
`votes` was the one table `anon` could read, insert into and update, and only
because of our leftovers. It now answers `anon` the way its siblings do.

The file names exact objects because the inspection found two things the
earlier, inferring version had wrong. It would have disabled RLS on `votes` —
seeing no other policies and concluding the RLS was ours — which would have
made that hole permanent. The rule was sound in the abstract and wrong about
this database.

Still owed: opening foodfinder and running a vote session end to end. RLS never
applied to it, so nothing should have changed — but that is a prediction, and
this project has lost time to predictions twice.

**Open**
- **Keep-alive.** `.github/workflows/keepalive.yml` pings daily. GitHub disables
  scheduled workflows in repos idle 60 days; a Cloudflare Worker cron has no
  such rule if that ever bites.
- **A vanished moderator strands the room.** Verified: with the moderator gone,
  no seated player can write `round` and none can reveal — there is no timeout
  and no host override, and `pol_rooms_clear` only lets the moderator delete. A
  reload recovers, since the session persists, so this needs a real
  disappearance. Judged expected behaviour for now: the moderator leaving ends
  the game. An escape hatch — an RPC letting any seated player pass the gavel
  after an idle timeout — is the fix if that changes.
- **`pol_reveal()` accepts a caller with no session.** The guard in
  [`rls-1-reveal-function.sql`](supabase/rls-1-reveal-function.sql) reads
  `if auth.uid() is not null and ...`, which was the deliberate escape hatch
  while the world was still permissive. rls-3 is applied now, so anyone holding
  a live room code and the publishable key can end a round early — the
  moderator loses the pairs from whoever had not voted yet. Confirmed against
  the live project with a throwaway room. Judged low stakes for a party game
  and left alone; the fix is dropping `auth.uid() is not null and` and granting
  execute to `authenticated` only, which was tested locally and keeps scoring
  parity at 200/200.

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
`request.jwt.claim.sub` — takes `setup.sql` and all four `rls-*.sql` files as
they are, which is how the scoring change and every policy in `rls-3` were
verified before anyone touched the live project. `set role authenticated; set
request.jwt.claim.sub = '<uuid>';` is enough to play a policy through. Use `set
role`, never `set local role`: outside a transaction the latter is a no-op and
silently leaves you as the owner, who bypasses RLS entirely.

The browser can be driven without network access too. Chromium is installed but
cannot reach the internet through the agent proxy, so: serve `index.html` from a
fake `https://` origin with Playwright's `ctx.route()`, fulfil the jsDelivr
bundle from a copy fetched with `curl`, and relay every `supabase.co` request
through node `fetch` — which does work — back into the page with an
`access-control-allow-origin` header. The realtime websocket stays dead under
that setup, so the game runs on the 2s poll, which is a fair test of invariant 2
rather than a broken one. Two traps worth knowing: `innerText` applies CSS
`text-transform`, so every `.eyebrow` and `.mono` string comes back uppercased —
match on `textContent`; and `document.body.textContent` includes the inline
`<script>` source, so assertions must be scoped to `#app` or they match the
template literals rather than the screen.
