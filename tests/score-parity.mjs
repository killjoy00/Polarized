// Run: node tests/score-parity.mjs
//
// Writes throwaway rooms (code prefix ZZ) to the LIVE Supabase project and
// deletes them again. Safe to run against production — it never touches a
// room it did not create — but it is not free, so do not loop it.
//
// Property test: does pol_reveal() in Postgres score exactly like score() in index.html?
const U = "https://hqvqxwlgjjxufbjklfhj.supabase.co";
const K = "sb_publishable_NCRLW3byhByVaQpfobY0Zg_WaReRFRc";
const H = { apikey: K, Authorization: `Bearer ${K}`, "Content-Type": "application/json" };

// ── verbatim from polarized/index.html ──────────────────────────────
function score(round, votes){
  votes = votes || {};
  const order = round.order || [];
  const live = order.filter(id => votes[id] && (round.modCounts || id !== round.modId));
  const agree    = live.filter(id => votes[id] === "a");
  const disagree = live.filter(id => votes[id] === "d");
  const pairs = Math.min(agree.length, disagree.length);
  let wolf = null;
  if (agree.length === 1 && disagree.length >= 2) wolf = agree[0];
  if (disagree.length === 1 && agree.length >= 2) wolf = disagree[0];
  if (wolf === round.modId) wolf = null;
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

function scenario(i){
  const n     = 3 + rnd(6);                       // 3..8 seats
  const order = Array.from({length:n}, (_,k) => `p${k}`);
  const modId = order[rnd(n)];
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
           round: { n:1, modId, phase:"voting", order,
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

console.log(`ran ${results.length} scenarios, ${failed.length} mismatches`);
console.log(`covered: lone-wolf ${results.filter(r => expectedScores(r.sc.round, r.sc.votes).r.wolf).length}` +
            `, zero-pair ${results.filter(r => expectedScores(r.sc.round, r.sc.votes).r.pairs === 0).length}` +
            `, modCounts ${results.filter(r => r.sc.round.modCounts).length}` +
            `, distinct shapes ${Object.keys(seen).length}`);
for (const f of failed.slice(0, 8)) console.log("MISMATCH", shape(f), f.problems.join(" | "));
process.exit(failed.length ? 1 : 0);
