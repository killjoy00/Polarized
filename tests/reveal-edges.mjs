// Run: node tests/reveal-edges.mjs
//
// Edge cases the random property test in score-parity.mjs will not reliably
// generate. Same deal: throwaway six-character ZZ rooms on the live project.
//
import { U, signIn } from "./live.mjs";

const { me: ME, headers: H, signedIn } = await signIn();

const api = async (p, o={}) => { const r = await fetch(U+"/rest/v1/"+p, {headers:H, ...o});
  const t = await r.text(); return { status:r.status, body: t ? JSON.parse(t) : null }; };

async function setup(code, round, votes){
  await api(`pol_rooms?code=eq.${code}`, {method:"DELETE"});
  await api("pol_rooms", {method:"POST", body:JSON.stringify({code, round})});
  const rows = Object.entries(votes).map(([pid,choice]) => ({code, n:1, pid, choice}));
  if (rows.length) await api("pol_votes", {method:"POST", body:JSON.stringify(rows)});
}
const read = async code => (await api(`pol_rooms?code=eq.${code}&select=round`)).body[0].round;
const reveal = code => api("rpc/pol_reveal", {method:"POST", body:JSON.stringify({p_code:code})});
// the moderator is this session — pol_reveal() will not score a round for anyone else
const base = (order, modCounts=false, scores={}) =>
  ({n:1, modId:ME, phase:"voting", order, names:Object.fromEntries(order.map(i=>[i,i])), scores, modCounts, laps:2});
const seats = n => [ME, ...Array.from({length:n-1}, (_,k) => `p${k+1}`)];

const check = (label, ok, detail="") => console.log(`${ok ? "PASS" : "FAIL"}  ${label}${detail ? "  " + detail : ""}`);
let bad = 0;
const expect = (label, ok, detail) => { if (!ok) bad++; check(label, ok, detail); };

// 1. double reveal must not score twice — five seats, so the wolf bonus is in play
{
  const c="ZZED01", o=seats(5);
  await setup(c, base(o), {p1:"a",p2:"a",p3:"a",p4:"d"});
  await reveal(c);
  const first = await read(c);
  await reveal(c);
  const second = await read(c);
  expect("double reveal is idempotent",
         JSON.stringify(first.scores)===JSON.stringify(second.scores) && first.scores.p4===1,
         `${JSON.stringify(first.scores)} -> ${JSON.stringify(second.scores)}`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}

// 2. nobody voted
{
  const c="ZZED02", o=seats(3);
  await setup(c, base(o), {});
  await reveal(c);
  const r = await read(c);
  expect("no votes at all", r.phase==="reveal" && r.scores[ME]===0,
         `phase=${r.phase} scores=${JSON.stringify(r.scores)}`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}

// 3. moderator would be the lone wolf, with modCounts on — must be suppressed
{
  const c="ZZED03", o=seats(5);
  await setup(c, base(o, true), {[ME]:"a",p1:"d",p2:"d",p3:"d",p4:"d"});
  await reveal(c);
  const r = await read(c);
  expect("moderator never takes lone wolf", r.scores[ME]===1,
         `scores=${JSON.stringify(r.scores)} (expect 1 pair only, no +1)`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}

// 4. unanimous room — no pairs, no wolf
{
  const c="ZZED04", o=seats(4);
  await setup(c, base(o), {p1:"a",p2:"a",p3:"a"});
  await reveal(c);
  const r = await read(c);
  expect("unanimous scores nothing", r.scores[ME]===0, `scores=${JSON.stringify(r.scores)}`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}

// 5. reveal from a phase that isn't voting must be a no-op
{
  const c="ZZED05", o=seats(3);
  await setup(c, {...base(o), phase:"topic"}, {p1:"a",p2:"d"});
  await reveal(c);
  const r = await read(c);
  expect("no reveal from topic phase", r.phase==="topic" && !r.revealed, `phase=${r.phase}`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}

// 6. a vote from someone not seated is ignored for scoring but still revealed
{
  const c="ZZED06", o=seats(3);
  await setup(c, base(o), {p1:"a",p2:"d",ghost:"d"});
  await reveal(c);
  const r = await read(c);
  expect("unseated vote ignored in scoring", r.scores[ME]===1 && r.revealed.ghost==="d",
         `scores=${JSON.stringify(r.scores)} revealed=${JSON.stringify(r.revealed)}`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}

// 7. the lone wolf bonus starts at five seats — four is one short
{
  const c="ZZED07", o=seats(4);
  await setup(c, base(o), {p1:"a",p2:"a",p3:"d"});
  await reveal(c);
  const r = await read(c);
  expect("four seats: no lone wolf", r.scores.p3===undefined && r.scores[ME]===1,
         `scores=${JSON.stringify(r.scores)}`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}

// 8. …and five seats pays it
{
  const c="ZZED08", o=seats(5);
  await setup(c, base(o), {p1:"a",p2:"a",p3:"a",p4:"d"});
  await reveal(c);
  const r = await read(c);
  expect("five seats: lone wolf paid", r.scores.p4===1 && r.scores[ME]===1,
         `scores=${JSON.stringify(r.scores)}`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
}

// 9. only the moderator ends the round. Nothing to test without a session —
//    the check in pol_reveal() is deliberately inert for a caller who has none.
if (signedIn){
  const c="ZZED09", o=["p0","p1","p2","p3","p4"];
  await setup(c, {...base(o), modId:"p0"}, {p1:"a",p2:"a",p3:"a",p4:"d"});
  const res = await reveal(c);
  const r = await read(c);
  expect("a non-moderator cannot reveal", r.phase==="voting" && res.status >= 400,
         `status=${res.status} phase=${r.phase}`);
  await api(`pol_rooms?code=eq.${c}`,{method:"DELETE"});
} else {
  console.log("SKIP  a non-moderator cannot reveal  (no anonymous session)");
}

process.exit(bad ? 1 : 0);
