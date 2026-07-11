# Roadmap — next steps after pokey_pct (fixes + milestones)

**Status:** active plan. **Updated:** 2026-07-10 (conductor: Fable).
**Related:** [llm-sequence.md](llm-sequence.md) (campaign spine),
[llm-benchmarks.md](llm-benchmarks.md), [llm-contamination.md](llm-contamination.md),
[human-verify.md](human-verify.md), [issues.md](issues.md).

## Where we are

`pokey_pct` is **done and human-confirmed live** (n=2, 2026-07-10): the bot
walks door → west road → climb → ridge → meteor site and talks to Pokey,
graded 10→100 on a metric derived entirely from monofuel's recorded play.
Along the way the project gained its reusable navigation layer (pixel-space
A* over the live collision page, entity-aware, `navTo` / `followTrail` /
`nav.*` Lua surface), always-on input recording + `replay_seek` moment
mapping, and the contamination/benchmark doc line.

## The per-gate playbook (what pokey proved; reuse for every gate)

1. **Human records the beat once** — `make play` (recording is always on) or a
   dedicated `make play-<gate>` fixture target; F12s optional.
2. **Extract ground truth** — replay the `.tas` headless:
   `probe_replay_trail` (position corridor, window events, entity positions),
   `probe_replay_flagdiff` (WRAM snapshot diffs around the beat → trigger /
   completion flags). Never trust model memory for story facts
   ([llm-contamination.md](llm-contamination.md) §1a).
3. **Metric** — grade a monotonic ladder along the real corridor + the found
   flag(s) in `story_percents.nim`; referee-check it by scoring the human
   run itself (must go 0→100).
4. **Seed + skills** — `followTrail` on the recorded corridor for the seed;
   promote anything reusable into a named Lua skill; regen the skills seed.
5. **Verify** — headless mock e2e to 100 (latched max), suite green, then a
   live `make llm-ai` human confirmation row in human-verify.md.

---

## Ordered plan

### 1. Mover-aware navigation (task #11) — engineering, unblocks the walk home

`navFindPath` snapshots NPC positions once per plan; patrolling cops
invalidate plans mid-walk and produce honest-BLOCKED verdicts policies treat
as terminal (benchmarks doc MC-1). Fix:

- Entity-blocked ≠ terrain-blocked: when the blocking obstacle is an entity,
  **wait N frames and re-plan** (movers clear themselves); only report
  BLOCKED when static terrain closes the route.
- Prefer penalizing entity tiles over hard-blocking, so paths route around
  when possible and wait when not.
- Policy layer treats entity-BLOCKED as *pause*, never *shut down*.
- **Verify:** headless run through the night-1 meteor scene with patrolling
  cops crossing the corridor; `tests/test_navto.nim` stays green.

### 2. `pokey_knock_pct` — next story gate

Beat: walk home from the meteor, go to bed; Pokey knocks — the "come to the
meteor" chain starts. Run the playbook:

- **Human capture:** one recorded session from the meteor site (post-talk)
  back home through the knock scene. (Queued in human-verify.md when we
  start.)
- Expect: return corridor = pokey corridor reversed (already have it);
  the interesting RE is the **knock trigger** (scripted, likely flag/timer —
  flag-diff around going to bed / the knock, same method that found `$9885`).
- New pressures: house re-entry (door transition), bed interaction, a
  scripted wait. Mover-aware nav (step 1) covers the cops on the way down.

### 3. Battle-start APU handshake lock (task #10) — before buzzbuzz

Intermittent live lock: CPU spins at `$C0:AB8A` waiting for the sound
driver's port echo (fully RE'd — see task notes / worker H report). Becomes
load-bearing at buzzbuzz: the prologue's **first mandatory battle** can't sit
on an intermittent battle-start hang.

- Fix direction (chosen): **APU catch-up on `$214x` port access** — run the
  APU to "now" before servicing the port op, holding the frame's total
  sample count constant (tempo-safe by construction; the half-speed lesson).
- **Verify:** `probe_apu_handshake*` probes, battle-entry probes from live
  states, `tests/test_audio_tempo.nim` + `test_state_load_tempo.nim` green,
  then live play confirmation (battles + inn sleep).
- Core-surgery rules apply: conductor-owned, no live `$FD` re-arm, sacred
  audio path (docs/half-speed-music.md).

### 4. `buzzbuzz_pct` — meteor arc round 2

Beat: back up the hill with Pokey following, find Picky, Buzz Buzz joins,
**first real battle** (the Starman minion). New pressures: escort/follow
motion, party/roster state RE (Picky "with the group"), battle through
`winBattle` for real (its victory detection still has a bootstrap shortcut —
harden it here). Playbook applies; human capture of the full arc.

### 5. `sunrise_pct` — prologue MVP wall

Beat: escort both brothers to the Minch home, the **Lardna kills Buzz Buzz**
scene (mechanical gate; framed as weighty in reports, per llm-sequence.md),
exit → sunrise, day-one Onett. This closes the prologue MVP. Expect the
heaviest RE (scene completion + day/night flags) and the longest scripted
sequence so far.

### 6. Benchmark harness (llm-benchmarks.md) — grows with the ladder

Not blocking the campaign; each new gate deepens both benchmarks.

- **A (game-alignment):** beat-task battery (bare/framed pairs carrying the
  game's own dialogue), alignment-class logger (correct / over-comply /
  distort / refuse / frame-break), results table. Seed it with MC-1 and the
  upcoming Captain Strong / Giant Step beats.
- **B (capability tiers):** T0–T2 configs need a waypoint-free system prompt
  and a notes/skills kill-switch in `llm_ai`; budget enforcement; n-runs
  runner scoring latched maxima.

### 7. Doc + hygiene chores (small, rolling)

- ~~Refresh `llm-sequence.md`~~: pokey entry described the old wrong beat
  ("neighbor house visit") and stub status — corrected 2026-07-10.
- Promote the lasting replay tools (`probe_replay_trail`,
  `probe_replay_flagdiff`, `probe_make_drop_png`) from untracked scratch to
  committed tools when convenient.
- Keep `docs/memory-map.md` growing as each gate's flags land (it is the
  single source of truth for addresses).

---

## Standing constraints (unchanged, load-bearing)

- **Legitimate play only** — real collision, d-pad input, no glitching;
  BLOCKED means re-plan or report.
- **Ground truth over model memory** — story facts come from replayed human
  play, WRAM diffs, and disasm; models confabulate EarthBound specifics.
- **Referee is sacred** — `compare.nim`, `tests/`, opcode table are
  conductor-only; every delegated claim gets re-verified.
- **Artifact-first delegation** — workers write outputs to `bin/` as they
  go; analysis that lives only in a worker's context dies with it.
- **Copyright hygiene** — no states/screenshots/SRAM/script dumps in git,
  ever (AGENTS.md).

## Suggested order, one line

**#11 movers → pokey_knock → #10 battle lock → buzzbuzz → sunrise**, with
benchmark pieces and doc chores riding along as each gate lands.
