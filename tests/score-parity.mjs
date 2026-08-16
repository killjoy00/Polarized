// Run: node tests/score-parity.mjs
//
// Writes throwaway rooms (six-character ZZ codes) to the LIVE Supabase project
// and deletes them again. Safe to run against production — it never touches a
// room it did not create — but it is not free, so do not loop it.
//
// Property test: does pol_reveal() in Postgres score exactly like score() in index.html?
import { U, signIn } from "./live.mjs";

const { me: ME, headers: H } = await signIn();

// ── verbatim from polarized/index.html ──────────────────────────────
const WOLF_MIN_SEATS = 5;

function score(round, votes){
  votes = votes || {};
  const order = round.order || [];
  const live = order.filter(id => votes[id] && (round.modCounts || id !== round.modId));
  const agree    = live.filter(id => votes[id] === "a");
  const disagree = live.filter(id => votes[id] === "d");
  const pairs = Math.min(agree.length, disagree.length);
  let wolf = null;
  if (order.length >= WOLF_MIN_SEATS){
    if (agree.length === 1 && disagree.length >= 2) wolf = agree[0];
    if (disagree.length === 1 && agree.length >= 2) wolf = disagree[0];
    if (wolf === round.modId) wolf = null;
  }
  return {agree, disagree, pairs, wolf};
}
// what reveal() used to do in the browser
function expectedScores(round, votes){
  const r = score(round, votes);
  const scores = Object.assign({}, round.scores);
  scores[round.modId] = (scores[round.modId] || 0) + r.pairs;
  if (r.wolf) scores[r.wolf] = (scores[r.wolf] || 0) + 1;
  return { scores, r };
}
// ────────────────────────────────────────────────────────────────────

// jsonb normalises key order; JS preserves insertion order. Compare by value.
const canon = o => JSON.stringify(Object.fromEntries(Object.entries(o||{}).sort(([a],[b]) => a < b ? -1 : 1)));

const rnd = n => Math.floor(Math.random() * n);
const api = async (path, opts={}) => {
  const res = await fetch(U + "/rest/v1/" + path, { headers: H, ...opts });
  if (!res.ok && res.status !== 204) throw new Error(path + " -> " + res.status + " " + await res.text());
  return res.status === 204 || res.headers.get("content-length") === "0" ? null : res.json().catch(() => null);
};

// The moderator is always this session: pol_reveal() refuses to score a round
// for anyone else, and rls-3 will not let anyone else write the room either.
// Their seat still moves around, which is what the scoring rules care about.
function scenario(i){
  const n     = 3 + rnd(6);                       // 3..8 seats
  const order = Array.from({length:n}, (_,k) => `p${k}`);
  order[rnd(n)] = ME;
  const modCounts = Math.random() < 0.35;
  const votes = {};
  for (const id of order){
    const r = Math.random();
    // bias toward shapes that matter: splits, lone dissenters, unanimity
    if (r < 0.15) continue;                       // abstain
    votes[id] = r < 0.575 ? "a" : "d";
  }
  const scores = {};
  for (const id of order) if (Math.random() < 0.5) scores[id] = rnd(9);
  return { code: "ZZ" + i.toString(36).padStart(4,"0").toUpperCase(),
           round: { n:1, modId:ME, phase:"voting", order,
                    names: Object.fromEntries(order.map(id => [id, id.toUpperCase()])),
                    scores, modCounts, laps:2 },
           votes };
}

async function runOne(sc){
  await api("pol_rooms", { method:"POST", body: JSON.stringify({ code: sc.code, round: sc.round }) });
  const rows = Object.entries(sc.votes).map(([pid, choice]) => ({ code: sc.code, n:1, pid, choice }));
  if (rows.length) await api("pol_votes", { method:"POST", body: JSON.stringify(rows) });

  await api("rpc/pol_reveal", { method:"POST", body: JSON.stringify({ p_code: sc.code }) });

  const [room] = await api(`pol_rooms?code=eq.${sc.code}&select=round`);
  const got = room.round;
  const want = expectedScores(sc.round, sc.votes);

  const problems = [];
  if (got.phase !== "reveal") problems.push(`phase ${got.phase}`);
  if (canon(got.scores) !== canon(want.scores))
    problems.push(`scores db=${canon(got.scores)} js=${canon(want.scores)}`);
  if (canon(got.revealed) !== canon(sc.votes))
    problems.push(`revealed db=${canon(got.revealed)} sent=${canon(sc.votes)}`);

  await api(`pol_rooms?code=eq.${sc.code}`, { method:"DELETE" });
  return { sc, want, problems };
}

// Preflight. A database still running the old function disagrees with score()
// on a third of the scenarios below, which reads as forty confusing mismatches
// instead of one missing migration.
{
  const code = "ZZPRE0", order = [ME, "p1", "p2", "p3"];
  await api(`pol_rooms?code=eq.${code}`, { method:"DELETE" });
  await api("pol_rooms", { method:"POST", body: JSON.stringify({ code, round:
    { n:1, modId:ME, phase:"voting", order,
      names: Object.fromEntries(order.map(id => [id, id])), scores:{}, modCounts:false, laps:1 } }) });
  await api("pol_votes", { method:"POST", body: JSON.stringify(
    [{code, n:1, pid:"p1", choice:"a"}, {code, n:1, pid:"p2", choice:"a"}, {code, n:1, pid:"p3", choice:"d"}]) });
  await api("rpc/pol_reveal", { method:"POST", body: JSON.stringify({ p_code: code }) });
  const [row] = await api(`pol_rooms?code=eq.${code}&select=round`);
  const stale = (row.round.scores || {}).p3 === 1;
  await api(`pol_rooms?code=eq.${code}`, { method:"DELETE" });
  if (stale){
    console.log("pol_reveal() still awards the lone wolf in a four-seat room.");
    console.log("Re-run supabase/rls-1-reveal-function.sql on the project, then try again.");
    process.exit(1);
  }
}

const N = 120;
const results = [];
for (let i = 0; i < N; i += 8){
  const batch = Array.from({length: Math.min(8, N - i)}, (_, k) => scenario(i + k));
  results.push(...await Promise.all(batch.map(runOne)));
}

const failed = results.filter(r => r.problems.length);
const shape = r => {
  const s = score(r.sc.round, r.sc.votes);
  return `${s.agree.length}a/${s.disagree.length}d${s.wolf ? " wolf" : ""}${r.sc.round.modCounts ? " modCounts" : ""}`;
};
const seen = {};
for (const r of results) seen[shape(r)] = (seen[shape(r)] || 0) + 1;

const small = results.filter(r => r.sc.round.order.length < WOLF_MIN_SEATS);
console.log(`ran ${results.length} scenarios, ${failed.length} mismatches`);
console.log(`covered: lone-wolf ${results.filter(r => expectedScores(r.sc.round, r.sc.votes).r.wolf).length}` +
            `, zero-pair ${results.filter(r => expectedScores(r.sc.round, r.sc.votes).r.pairs === 0).length}` +
            `, modCounts ${results.filter(r => r.sc.round.modCounts).length}` +
            `, under ${WOLF_MIN_SEATS} seats ${small.length}` +
            `, distinct shapes ${Object.keys(seen).length}`);
for (const f of failed.slice(0, 8)) console.log("MISMATCH", shape(f), f.problems.join(" | "));
process.exit(failed.length ? 1 : 0);
