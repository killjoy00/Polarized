-- RLS hardening, part 1 of 3 — run this FIRST, on the Polarized project.
--
-- Purely additive: creates the function, changes no permissions. Safe to run
-- against the live game; the currently deployed app carries on working.
--
-- RE-RUN THIS when the scoring rules change. It is `create or replace` and
-- idempotent. Two rules moved after the first deployment: the lone wolf now
-- needs five seats, and only the moderator may reveal. `tests/score-parity.mjs`
-- fails loudly against a database still running the old body.
--
-- Why this exists: scoring used to happen in the browser, which meant every
-- client had to be able to read every vote before the reveal. That is a
-- cheating hole — devtools shows you the room's votes in time to pick the
-- lone dissenter. Scoring server-side is what lets part 2 take the votes away
-- from clients entirely.
--
-- This mirrors score() in index.html exactly. If you change one, change both.

create or replace function public.pol_reveal(p_code text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round     jsonb;
  v_n         integer;
  v_mod       text;
  v_modcounts boolean;
  v_order     jsonb;
  v_revealed  jsonb := '{}'::jsonb;
  v_agree     text[] := '{}';
  v_disagree  text[] := '{}';
  v_alen      integer;
  v_dlen      integer;
  v_pairs     integer;
  v_wolf      text := null;
  v_scores    jsonb;
  v_pid       text;
  i           integer;
begin
  -- lock the room so two taps on Reveal can't score the round twice
  select round into v_round from public.pol_rooms where code = p_code for update;

  if v_round is null then
    raise exception 'no round for room %', p_code;
  end if;

  -- only a room that is actually voting can be revealed; makes this idempotent
  if v_round->>'phase' is distinct from 'voting' then
    return;
  end if;

  -- Only the moderator ends the round. auth.uid() is null for a caller with no
  -- session, which keeps this inert until anonymous sign-in is switched on and
  -- rls-3 has been applied — the permissive world carries on working meanwhile.
  if auth.uid() is not null
     and v_round->>'modId' is distinct from auth.uid()::text then
    raise exception 'only the moderator can reveal this round';
  end if;

  v_n         := (v_round->>'n')::integer;
  v_mod       := v_round->>'modId';
  v_modcounts := coalesce((v_round->>'modCounts')::boolean, false);
  v_order     := coalesce(v_round->'order', '[]'::jsonb);

  -- every vote for this round, moderator included — the reveal screen renders
  -- from this, and score() re-applies the modCounts rule client-side
  select coalesce(jsonb_object_agg(pid, choice), '{}'::jsonb)
    into v_revealed
    from public.pol_votes
   where code = p_code and n = v_n;

  -- walk seats in turn order so pairing matches what the client draws
  for i in 0 .. coalesce(jsonb_array_length(v_order), 0) - 1 loop
    v_pid := v_order->>i;
    if (v_revealed ? v_pid) and (v_modcounts or v_pid is distinct from v_mod) then
      if v_revealed->>v_pid = 'a' then
        v_agree := v_agree || v_pid;
      elsif v_revealed->>v_pid = 'd' then
        v_disagree := v_disagree || v_pid;
      end if;
    end if;
  end loop;

  v_alen  := coalesce(array_length(v_agree, 1), 0);
  v_dlen  := coalesce(array_length(v_disagree, 1), 0);
  v_pairs := least(v_alen, v_dlen);

  -- lone wolf: exactly one on a side, at least two on the other — and only at
  -- five seats or more. Below that, standing alone is a coin flip rather than
  -- a stand. Mirrors WOLF_MIN_SEATS in index.html; seats, not votes cast.
  if coalesce(jsonb_array_length(v_order), 0) >= 5 then
    if v_alen = 1 and v_dlen >= 2 then
      v_wolf := v_agree[1];
    elsif v_dlen = 1 and v_alen >= 2 then
      v_wolf := v_disagree[1];
    end if;
    if v_wolf is not distinct from v_mod then
      v_wolf := null;                    -- the moderator never takes it
    end if;
  end if;

  v_scores := coalesce(v_round->'scores', '{}'::jsonb);
  v_scores := jsonb_set(v_scores, array[v_mod],
                to_jsonb(coalesce((v_scores->>v_mod)::integer, 0) + v_pairs), true);
  if v_wolf is not null then
    v_scores := jsonb_set(v_scores, array[v_wolf],
                  to_jsonb(coalesce((v_scores->>v_wolf)::integer, 0) + 1), true);
  end if;

  update public.pol_rooms
     set round = v_round || jsonb_build_object(
                   'phase',    'reveal',
                   'scores',   v_scores,
                   'revealed', v_revealed)
   where code = p_code;
end $$;

grant execute on function public.pol_reveal(text) to anon, authenticated;
