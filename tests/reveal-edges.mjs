// Run: node tests/reveal-edges.mjs
//
// Edge cases the random property test in score-parity.mjs will not reliably
// generate. Same deal: throwaway ZZ-prefixed rooms on the live project.
//
const U = "https://hqvqxwlgjjxufbjklfhj.supabase.co";
const K = "sb_publishable_NCRLW3byhByVaQpfobY0Zg_WaReRFRc";
const H = { apikey: K, Authorization: `Bearer ${K}`, "Content-Type": "application/json" };
const api = async (p, o={}) => { const r = await fetch(U+"/rest/v1/"+p, {headers:H, ...o});
  const t = await r.text(); return { status:r.status, body: t ? JSON.parse(t) : null }; };

async function setup(code, round, votes){
  await api(`pol_rooms?code=eq.${code}`, {method:"DELETE"});
  await api("pol_rooms", {method:"POST", body:JSON.stringify({code, round})});
  const rows = Object.entries(votes).map(([pid,choice]) => ({code, n:1, pid, choice}));
  if (rows.length) await api("pol_votes", {method:"POST", body:JSON.stringify(rows)});
}
const read = async code => (await api(`pol_rooms?code=eq.${code}&select=round`)).body[0].round;
const base = (modId, order, modCounts=false, scores={}) =>
  ({n:1, modId, phase:"voting", order, names:Object.fromEntries(order.map(i=>[i,i])), scores, modCounts, laps:2});

const check = (label, ok, detail="") => console.log(`${ok ? "PASS" : "FAIL"}  ${label}${detail ? "  " + detail : ""}`);

// 1. double reveal must not score twice
{
  const c="ZZED01";
  await setup(c, base("p0",["p0","p1","p2","p3"]), {p1:"a",p2:"a",p3:"d"});
  await api("rpc/pol_reveal",{method:"POST",body:JSON.stringify({p_code:c})});
  const first = await read(c);
  await api("rpc/pol_reveal",{method:"POST",body:JSON.stringify({p_code:c})});
  const second = await read(c);
  check("double reveal is idempotent",
        JSON.stringify(first.scores)===JSON.stringify(second.scores),
        `${JSON.stringify(first.scores)} -> ${JSON.stringify(second.scores)}`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}

// 2. nobody voted
{
  const c="ZZED02";
  await setup(c, base("p0",["p0","p1","p2"]), {});
  await api("rpc/pol_reveal",{method:"POST",body:JSON.stringify({p_code:c})});
  const r = await read(c);
  check("no votes at all", r.phase==="reveal" && r.scores.p0===0,
        `phase=${r.phase} scores=${JSON.stringify(r.scores)}`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}

// 3. moderator would be the lone wolf, with modCounts on — must be suppressed
{
  const c="ZZED03";
  await setup(c, base("p0",["p0","p1","p2"], true), {p0:"a",p1:"d",p2:"d"});
  await api("rpc/pol_reveal",{method:"POST",body:JSON.stringify({p_code:c})});
  const r = await read(c);
  check("moderator never takes lone wolf", r.scores.p0===1 && !("bonus" in r),
        `scores=${JSON.stringify(r.scores)} (expect p0=1 pair only, no +1)`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}

// 4. unanimous room — no pairs, no wolf
{
  const c="ZZED04";
  await setup(c, base("p0",["p0","p1","p2","p3"]), {p1:"a",p2:"a",p3:"a"});
  await api("rpc/pol_reveal",{method:"POST",body:JSON.stringify({p_code:c})});
  const r = await read(c);
  check("unanimous scores nothing", r.scores.p0===0, `scores=${JSON.stringify(r.scores)}`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}

// 5. reveal from a phase that isn't voting must be a no-op
{
  const c="ZZED05";
  await setup(c, {...base("p0",["p0","p1","p2"]), phase:"topic"}, {p1:"a",p2:"d"});
  await api("rpc/pol_reveal",{method:"POST",body:JSON.stringify({p_code:c})});
  const r = await read(c);
  check("no reveal from topic phase", r.phase==="topic" && !r.revealed, `phase=${r.phase}`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}

// 6. a vote from someone not seated is ignored for scoring but still revealed
{
  const c="ZZED06";
  await setup(c, base("p0",["p0","p1","p2"]), {p1:"a",p2:"d",ghost:"d"});
  await api("rpc/pol_reveal",{method:"POST",body:JSON.stringify({p_code:c})});
  const r = await read(c);
  check("unseated vote ignored in scoring", r.scores.p0===1 && r.revealed.ghost==="d",
        `scores=${JSON.stringify(r.scores)} revealed=${JSON.stringify(r.revealed)}`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}
