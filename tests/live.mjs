// Shared bootstrap for the tests that run against the live project.
//
// Both test files write throwaway rooms with six-character ZZ codes. Real
// rooms are four characters, and supabase/rls-3-anon-auth.sql keys its one
// test exemption to exactly that difference — so nothing here can touch a
// room somebody is playing in.

export const U = "https://hqvqxwlgjjxufbjklfhj.supabase.co";
export const K = "sb_publishable_NCRLW3byhByVaQpfobY0Zg_WaReRFRc";

/* The game signs in anonymously and uses auth.uid() as its player id. After
   rls-3 the tests cannot write anything without doing the same; before it,
   either way works. A project with anonymous sign-ins still switched off is a
   warning, not a failure — say so and carry on with the publishable key. */
export async function signIn(){
  const res = await fetch(U + "/auth/v1/signup", {
    method: "POST",
    headers: { apikey: K, "Content-Type": "application/json" },
    body: '{"data":{}}'
  });
  const body = await res.json().catch(() => null);
  if (!res.ok || !body || !body.access_token){
    console.log(`note: no anonymous session (${(body && body.msg) || res.status})` +
                ` — running as anon. Fine until rls-3 is applied.`);
    return { me: "p0", headers: { apikey: K, Authorization: `Bearer ${K}`,
                                  "Content-Type": "application/json" }, signedIn: false };
  }
  return {
    me: body.user.id,
    headers: { apikey: K, Authorization: `Bearer ${body.access_token}`,
               "Content-Type": "application/json" },
    signedIn: true
  };
}
