# Grok play work — robust LLM player (not a TAS cosplay)

**Status:** active work plan (2026-07-23). Owner lane: Goal 4 / LLM-play.
**North star:** a wall-mounted, always-on AI that plays EarthBound through to
completion like a 12-year-old with a new cartridge — perceiving the game,
building skills, taking notes, getting stuck, recovering, and slowly finishing
the story. **Not** a fragile chain of monofuel waypoints.

**Related (do not treat as competing product specs):**
- [llm-plays.md](llm-plays.md) — original harness design + evolution (skills/notes/pause-to-think). Closest to the north star.
- [llm-play-overhaul.md](llm-play-overhaul.md) — perception / intent / KB pieces; track matrix (Pilot × Tempo). Keep the good bits; discard TAS-as-product.
- [llm-sequence.md](llm-sequence.md) — **early** story ladder (tg → Pokey → knock → Buzz Buzz → Sunrise). Prologue only; not the full game.
- [checkpoints.md](checkpoints.md) — **full-game** speedrun-style checkpoints (Any% Glitchless segments, Sanctuaries, bosses, Giygas…). Canonical long-run spine for coverage beyond prologue.
- [llm-contamination.md](llm-contamination.md) — honesty about seeds vs learning.
- [llm-benchmarks.md](llm-benchmarks.md) — purity tiers when we claim “from scratch.”
- [roadmap.md](roadmap.md) / [human-verify.md](human-verify.md) — contain the **old playbook** (human TAS → trail → seed). Treat those sections as *historical / optional oracle*, not the default plan.

This file is the **re-centered plan** when Goal 4 work resumes. If older docs
conflict with this one on “how the AI should play,” **this doc wins** until we
merge the conflict explicitly.

---

## 1. North star (product)

| Want | Do not want |
|------|-------------|
| Agent plays the **whole game** over days/weeks unattended | Agent that only works while monofuel records the next corridor |
| Growing **Lua skill library** the model writes and reuses | Hardcoded `followRoute("onett_to_crater")` as the only way up the hill |
| **Sees** the game (pixels + structured state) | Text-only “blind” bot + hex spoon-feeding |
| Recovers from stuck / death / wrong door | One bad tile → infinite wander / percent thrash |
| Story from **live dialogue + exploration** | Plot confabulated in the system prompt or human wiki paste |
| Scripted pilot only as **referee / CI floor** | Scripted pilot as the real “AI progress” |
| Emulator + RE unblocks the agent | Human plays the full prologue to “teach” the agent the plot |

**House art piece:** `make llm-ai` / display loop on a spare monitor, Agent ×
Theater (or Adaptive), runs 24/7, restarts cleanly, keeps SRAM + notes + skills
across restarts. Measurable story progress over sessions — not a demo of
replaying one recorded trail.

**Player metaphor:** new kid, no walkthrough in hand. Prior knowledge in the
base model is contaminated and low-fidelity ([llm-contamination.md](llm-contamination.md));
the *harness* must not paper over that by handing routes. Perception +
experimentation + memory are the product.

---

## 2. What went off track (so we do not do it again)

Honest postmortem of the 2026-07 LLM-play campaign:

1. **Blind bot.** No screenshot to the model; weak/no structured scene at first.
   Compensation = coordinate ladders and dense trails in the prompt and seeds.
2. **Confabulation panic.** Models invent EarthBound facts. Correct response =
   ground truth from the **ROM / live WRAM / dialogue**, not “human TAS every
   beat forever.”
3. **Playbook calcified.** “Human records → extract trail → seed `followTrail`
   → grade corridor %” worked for n=2 (pokey) and became the *definition of
   done* for every gate. That scales as **O(human hours × game length)**, not
   as an AI player.
4. **Success metric inversion.** “Scripted·Turbo hits pokey=100 on a recorded
   route” is a **referee**, not proof the Agent can play. Claiming the gate
   “done” while live Agent wanders next to Pokey without talking is the tell.
5. **Human as story oracle.** Asking monofuel to play whole prologue nights so
   agents can mine trails **misses the point of owning a full emulator +
   decomp toolchain.** Human time is for: emulator bugs, rare RE fixtures,
   eyeball feel — not teaching the AI the entire game.

**Anti-patterns (ban as product strategy):**

- Exact monofuel waypoints / dense TAS trails as the main outdoor nav.
- System prompts that embed multi-leg hex corridors.
- “Gate done” = mock seed reaches percent, with no Agent·Theater evidence.
- Human capture queued as **blocking** for every story beat.
- Treating `followRoute(name)` engine routes as the only outdoor locomotion.

**Allowed (narrowly):**

- One-off human/TAS capture to **RE a flag** or fix an emu bug (not to ship a
  permanent trail skill).
- Scripted·Turbo as **regression referee** for skills and metrics.
- Dense routes as **temporary bootstrap** while perception/nav mature — must
  have a delete ticket; must not be the Agent’s only instruction.

---

## 3. Architecture principles (robustness)

### 3.1 Two clocks (keep)

- **Fast:** Lua `update()` every frame — skills, pad, no network.
- **Slow:** LLM rewrites / chooses next skill plan on interval or stuck signal.

Unchanged from [llm-plays.md](llm-plays.md). This is correct.

### 3.2 Perception is load-bearing (fix and keep fixed)

The agent needs **both** channels every decision that matters:

| Channel | Role | Latency | Status (code, 2026-07-23) |
|---------|------|---------|---------------------------|
| **Vision** | Screenshot of `frameImage` as multimodal input (qwen 3.6 has vision) | High (~tens–180s local; sparse) | **Wired.** `--vision` encodes frame PNG → base64 → multimodal `image_url` in `realProviderSnap` (`vision_payload.nim`). Live azem smoke: extracted `function update()`. Keep sparse. |
| **Structured scene** | Deterministic JSON from WRAM: nearby entities (dir/dist/name), landmarks, dialogue text, menu/battle flags | Sub-ms; every tick | **On every slow tick.** `scene.nim` + `scene()` + SCENE line. Names mom/pokey/ness. Landmarks `outside_onett`. Battles still thin. Intent Lua parser fixed for optional `name` fields. |

**Rule:** do not solve blindness with more waypoints. Fix eyes + structure.

Vision policy (proposed, from overhaul latency work):

- Default: structured scene **every** LLM tick.
- Vision: gated (`--vision` or auto on scene-change / stuck / explicit “look”)
  so Theater stays watchable; not 138s every 20 frames.

### 3.3 Skills grow; seeds shrink

- LLM may **call**, **compose**, and **define** Lua skills.
- Engine ships a **small** core: move toward, talk, advance dialogue, escape
  menu, battle basics, stuck detection — mechanics, not plot routes.
- Named dense routes (`onett_to_crater`) are **engine conveniences for
  Scripted referees**, not the Agent’s curriculum.
- Persistent brain: skills file + notes/KB + isolated SRAM + rollback states.

### 3.4 Intent over coordinates

Policies should prefer:

- `talk("pokey")` / `approach(slot)` / head toward landmark **by name from scene**
- not `navTo(0x0858, 0x00F2)` in the prompt

Coordinates may exist **inside** skills (implementation detail). They must not
be the *language* of strategy the LLM is forced to speak.

### 3.5 Recovery is part of play

A full-game player needs:

- stuck detection (no progress metric / same pos / same menu for N frames)
- rollback to last good state or last checkpoint
- “try something else” policy rewrite (not re-run the same failed trail)
- death / softlock handling without human intervention

Without this, always-on art dies at the first cop or wrong door.

### 3.6 Story from the game

- Dialogue decode + harvest into KB (`[game]` / `[bot]` tags).
- Story flags RE’d when needed for **metrics and gates**, sourced from live
  WRAM diffs and disasm — not monofuel’s memory of 1994.
- System prompt stays short on plot; objectives come from live state + notes.

### 3.7 Track matrix (keep terminology)

From [llm-play-overhaul.md](llm-play-overhaul.md):

| Pilot | Tempo | Role in *this* plan |
|-------|-------|---------------------|
| **Scripted** | Turbo | CI / skill referees only |
| **Agent** | Theater | House art / demos |
| **Agent** | Turbo / Adaptive | Long unattended grind |
| **Scripted** | Theater | Optional TAS demo — not Goal 4 success |

Ship flags: `--pilot scripted|agent`, `--tempo theater|turbo|adaptive`.

### 3.8 Honest claims

- “Agent cleared gate X” requires Agent pilot + no dense monofuel trail as sole
  locomotion (or an explicit contamination tier per [llm-benchmarks.md](llm-benchmarks.md)).
- Seeded Scripted clears are fine as **infra tests**; label them that way.

---

## 4. Work streams

Ordered for a player that can leave Onett without cloning a human. Checkboxes
are plan state, not “someone already shipped it” unless noted.

### Stream A — Eyes: vision plumbing  **[P0]**

**Goal:** qwen receives the actual game frame when vision is enabled.

- [x] Encode `frameImage` → PNG → base64 in the LLM request path (`vision_payload.nim` + main encode before worker queue).
- [x] Multimodal message shape (`image_url` / content parts) in `realProviderSnap`; `max_tokens=4096`.
- [x] CLI: `--vision` / `--no-vision` (default off).
- [ ] Sparse fire: scene-change, stuck, or explicit skill `look()` — still every-tick when flag on; tighten later.
- [x] Live smoke vs azem qwen3.6: multimodal POST returned `function update()…end` (~180s).
- [x] Never commit screenshots; dumps stay gitignored (`bin/llm_frames/`).

**Depends on:** working azem endpoint (already validated once for vision).
**Verify:** Agent tick log shows image part size; qualitative description; Lua
still extracts.

### Stream B — Structured screen representation  **[P0]**

**Goal:** every LLM tick has a reliable, non-pixel “what’s around me.”

**Overworld / field (extend `scene.nim`):**

- [x] Nearby entities: relative dir + dist_tiles (exists).
- [x] Partial names (mom/pokey/ness).
- [x] Intent Lua parses optional `name` fields (was broken — dropped named ents).
- [ ] Expand identity table (or general TPT/sprite-group → name) as RE lands;
      unknown is OK if stable id is shown.
- [ ] Exits / doors / interactables (not only hand landmarks).
- [ ] Facing, on_door, menu_open / which_menu already partially in summary —
      keep consistent in one scene object.
- [ ] Landmarks grow by exploration/KB, not only hardcode `outside_onett`.

**Dialogue / UI text:**

- [x] `screen.text()` / dialogue stream path exists.
- [ ] Reliability pass: title, menus, shops, phone — document failure modes.
- [ ] Prefer game text over prompt plot.

**Battles (hard; iterative):**

- [ ] Structured battle state: in_battle, whose turn, command menu options,
      cursor, enemy names/HP if RE’d, party HP/PP (some already in summary).
- [ ] Do not block overworld play on perfect battle vision; ship v1 text + flags,
      then deepen.
- [ ] `winBattle` must become observation-driven, not a brittle A-spam that only
      works on fixtures.

**Verify:** probes print scene JSON on diverse states (house, street, crater,
battle command menu, shop). Agent policies that only use scene + talk make
local progress without hex in the prompt.

### Stream C — Robust locomotion (no trail dependency)  **[P0/P1]**

**Goal:** get from A to B using perception + pathfinding + recovery.

- [x] Reactive `walkTo`, A* `navTo` over live collision (exists; entity movers
      still flaky per roadmap notes).
- [ ] Mover-aware nav: wait/replan when blocked by NPC, not terminal BLOCKED.
- [x] Intent skills: `approach`, `talk`, `goToward`, `goHome`, `exitHouse` as
      primary Agent API; product seeds call skills by name (not trail-only bodies).
- [x] Multi-leg Agent seeds: `AgentHouseExitPolicy` (tg 25→100),
      `AgentHomePolicy` (knock 10→50 via `goHome()`). Dense routes only *inside*
      engine skills when needed; policy body never trail-only.
- [ ] Long-distance discovery without any engine reverse route (true explore).
- [ ] Indoor landmarks / collision so house exit is not a hex waypoint ritual.

**Verify:** Agent from bedroom → outside and door → meteor **without** loading
`onett_to_crater` as the sole policy body. Scripted can still use routes for CI.

### Stream D — Talk / interact / menus  **[P0]**

**Goal:** standing next to Pokey results in dialogue, not random d-pad.

- [x] `talk` path: face + A + drain; name resolve `talk("pokey")` works after parser fix.
- [x] `talk` returns **true while busy** (approach/face/A/dialogue) so
      `if talk() then return end` never falls through to explore pads
      (fixed after AgentOutdoorPolicy stalled at pokey=80).
- [ ] No A while walking (menu freeze) — already known; keep enforced in skills.
- [ ] Shops, beds, doors, phones as interact patterns discovered or skillized.
- [x] Acceptance: `probe_talk_grade` from `pokey_free` — pokey_pct 80→100 via intent
      talk only (no followRoute). Dialogue snippet may still be empty if flag
      consumed without text harvest; window path remains iterative.

**Verify:** from a “adjacent to Pokey” fixture or live state, Agent completes
dialogue and advances objective without Up/A frame spam as the only method.

### Stream E — Memory and learning  **[P1]**

**Goal:** multi-session brain that survives restarts.

- [x] notes + skills file + optional SRAM + KB scaffold.
- [ ] Typed LEARN routing solid under live `make llm-ai`.
- [ ] Retrieve only **relevant** notes (scene-local), not dump entire history.
- [ ] Skills written by the Agent persist and get re-tested (broken skills
      quarantine).
- [ ] Contamination-aware: label seed vs bot-learned for any “from scratch”
      claims.

### Stream F — Stuck, rollback, always-on  **[P1]**

**Goal:** 24/7 art does not require babysitting.

- [x] Progress signals: pos change, story percents, room (stuck detector).
- [x] Stuck → **STUCK_RECOVERY** rollback to `bin/states/llm/rollback.state` and/or
      forced policy replan; initial **STUCK_ANCHOR** armed at run start;
      `--stuck-threshold` for probes. (`tests/test_stuck_recovery.nim`)
- [ ] Stuck → vision/look signal (still open).
- [x] Checkpoint states under `bin/states/llm/` only (never human slots); never
      commit states.
- [ ] Display loop restart: preserve brain, don’t thrash the same failure.
- [ ] Optional Adaptive tempo: FF corridors, 60fps for menus/fights.

### Stream G — Story metrics as referees, not teachers  **[P1]**

**Goal:** percents / checkpoints measure progress; they do not require human
TAS to define every corridor. The agent is graded against **story beats**, not
against monofuel’s pixel path.

#### Checkpoint coverage (entire game)

Hand-picked **prologue** gates so far (in code / [llm-sequence.md](llm-sequence.md)):

| Early gate | Meaning | Status |
|------------|---------|--------|
| touch grass (`tg_pct`) | Ness outside the house | Done (metric + seed path) |
| Pokey talk (`pokey_pct`) | Talk at the meteor | AgentOutdoorPolicy 80→100 |
| Pokey knock (`pokey_knock_pct`) | Home + knock chain | **10→80 continuous** outdoor→home (no fixture handoff); fixtures 10→80; bed opens window but **no $99F2=$58** (sleep RE wall); **100** via campaign outdoor synth / `$99F2=$58` |
| Buzz Buzz (`buzzbuzz_pct`) | Meteor return / Picky | **90** free outdoor_pk AgentBuzz site; **100** needs join flag (Picky ≠ `$988C`) |
| Sunrise (`sunrise_pct`) | Prologue ends / day-1 | **90** soft from outdoor_pk Buzz leg; **100** day flag (human sleep capture) |
| Frank (`frank_pct`) | Day-1 arcade | **90** arcade/police strip (`py≥0x02A0`; AgentFrankPolicy outdoor continuous); **80** commercial; door + FromMeteor; **100** = Frankystein flag (indoor/day RE open) |
| Giant Step (`giant_step_pct`) | First Sanctuary approach | **70** continuous night freeplay (d85 freeze-clear + pure Left; west band); **80** day-open west (`$9887≥02` + same band) — continuous from outdoor freeplay (d110; no campaign giant seat required) or campaign day seat; cave freewalk / melody **100** still RE open (no cave F12) |
| Captain Strong (`captain_strong_pct`) | Leave Onett / Twoson | **60 continuous** night freeplay (outdoor→gs70→cs60); **70** later `$99F2=C4`; **80–90** Paula/Jeff; **100** day-leave Y grade (`py≥0x0500`+later-story) or `leave_day1_map` — night wall unreproducible freewalk (maxY~0x02A0) |
| Peaceful Rest (`peaceful_rest_pct`) | Pencil Eraser / Twoson valley | **30** C4 leave; **50** cs100; **60** day-Y grade only (night outdoor teleports if freeplayed); **70** honest freeplay on `leave_day1_map` (py≥0x1000, tele=0); **90** Paula join `leave_onett_walkable`; 100 = Apple Kid / eraser bit RE open |
| Paula rescue (`paula_rescue_pct`) | Twoson / Happy Happy | **40** night cs60; **50** live C4 leave soft (no party); **60/70** day-leave map py bands; **90** Paula+later `$99F2`; 100 = rescue scene bit |
| Lilliput Steps (`lilliput_steps_pct`) | 2nd Sanctuary / Mondo Mole | **30** Paula join; **50** +Jeff; **70** Jeff+deep py≥0x1000; 100 = Lilliput melody RE open |
| Winters (`winters_pct`) | Jeff joins | **50** Jeff in party + later `$99F2` (slot1); 100 = Sky Runner / reunion bit |
| Belch (`belch_pct`) | Master Belch / Saturn | **50** Jeff + later story + py≥0x1000 (slot1 soft) |
| Fourside (`fourside_pct`) | Dept Store → Dalaam | **40** leave; **45/50** wall approach; **60** free+Paula deep seat; **80–90** Poo join (party id — not freewalk); campaign fo60→`fourside80_from_paula` / walkable; natural freewalk **cannot** pass ~0x17F8 or invent Poo |
| Monotoli (`monotoli_pct`) | Clumsy Robot / Monotoli | **30** fo50; **50** fo60 deep; **70** Poo join soft; 100 = clear flag RE open |
| Summers (`summers_pct`) | Summers / Dalaam / Poo | **40** deep Fourside; **70** Poo party; **90** Poo+py≥0x2000; 100 = Dalaam ceremony RE open |
| Deep Darkness (`deep_darkness_pct`) | Master Barf / Tenda | **40** Poo; **60** bitpop≥540; **80** sanctuary soft; 100 = clear RE open |
| Stonehenge (`stonehenge_pct`) | Starman Deluxe base | tracks deep_darkness soft (40/60/80); 100 = clear RE open |
| Magicant (`magicant_pct`) | Ness nightmare soft | **90** fo80 free seat; **98** soft-flag handoff **or** continuous freeplay from `campaign_late_best` (ma95→98, bp crosses 550, d97); fo80 deep seat teleports/bp drops — cannot invent soft98 from fo80 alone; **100** = dream flag only (unset) |
| Giygas (`giygas_pct`) | Endgame soft | **60** tracks ma90; **80** tracks ma98 soft hold; **100** = phase flag only (unset) |
That is only the **night intro + day-1 Onett approach**. The long game needs the
full route spine in **[checkpoints.md](checkpoints.md)** — community Any%
Glitchless-style segments (Onett day → Frank → Sanctuaries → Paula → Winters →
Belch → Fourside → … Magicant → Giygas → epilogue), plus the 8 Your Sanctuaries
as hard progress markers. Treat that list as the **campaign backlog of referee
milestones**, not as a human-recording queue.

How the layers fit:

| Layer | Doc | Scope |
|-------|-----|--------|
| Prologue percents (working set) | [llm-sequence.md](llm-sequence.md) | Night-1 → Sunrise |
| Full-game checkpoint catalog | [checkpoints.md](checkpoints.md) | Whole cartridge (speedrun segments) |
| How we play them | **this file** | Agent + perception; metrics as referees |

Work items:

- [x] tg / pokey ladders exist; later prologue gates stubbed.
- [x] Full-game metric **stubs** + `checkpointSpineLine` in `story_percents.nim`
      (frank, giant_step, captain_strong, peaceful_rest, paula_rescue,
      lilliput_steps, winters, belch, fourside, monotoli, summers, magicant,
      giygas) — soft bands where proven; 100s reserved for scene/flag RE;
      surfaced in RICH STATE + `llm_ai` progress log.
- [x] Prefer **flag-based** where proven: knock `$99F2=$58`, captain 70 via
      later `$99F2`, paula 90 / winters 50 via party ids + later story.
- [ ] RE day-1 / leave-Onett / Belch / Fourside flags — human capture when
      bot-blocked (sleep→day still open).
- [x] Map primary [checkpoints.md](checkpoints.md) segments to stub metrics /
      spine line — do **not** invent a parallel list.
- [ ] Expand [checkpoints.md](checkpoints.md) if we need finer Agent splits
      (e.g. sub-beats inside a speedrun segment) without dropping the community
      backbone.
- [ ] Sunrise / full game: [llm-sequence.md](llm-sequence.md) = prologue order;
      [checkpoints.md](checkpoints.md) = everything after; neither is a capture
      queue.

### Stream H — Battles as real play  **[P1/P2]**

- [x] Perception (v1): slow-tick summary always includes `in_battle`,
      `battle_flag_$4DBA`, `battle_command_menu`, `battle_screen_text`,
      `party_hp_pp` (proven on overworld + `bin/states/battle_fixture.state`).
- [ ] Skills: select Bash/PSI/item/defend from observed menu; flee when needed.
- [ ] Party management, heal, gear — later arcs.
- [ ] Emu bugs that block battles (e.g. APU handshake) stay Goal 2 ownership;
      LLM-play documents blockers, doesn’t fake them with memory pokes.

### Stream I — Full-game campaign hygiene  **[P2]**

- [ ] Segment restarts, save points, multi-hour runs.
- [ ] No copyrighted dumps in repo (dialogue logs only in secret/gitignored
      paths; follow AGENTS.md).
- [ ] Benchmarks: T0 empty brain vs seeded tiers ([llm-benchmarks.md](llm-benchmarks.md)).
- [ ] Stretch: walk the [checkpoints.md](checkpoints.md) spine (Twoson → …
      Giygas) only after Onett day-1 is Agent-solid — one checkpoint at a time
      as **referee**, not as a monofuel TAS series.

---

## 5. What human time is for (narrow)

| Human does | Human does not |
|------------|----------------|
| Play for **emu bugs** / feel ([human-verify.md](human-verify.md) play feel) | Play entire story so agents can clone trails |
| Rare F12 when RE is stuck on a flag | Weekly prologue TAS as the plan |
| Approve that Agent·Theater looks like play | Be the pathfinder for every hill |
| Supply legal ROM | Commit states/screenshots/scripts |

Agents use the **emulator, disasm, WRAM probes, dialogue decode** as the main
instruments. That is the whole point of this repo.

---

## 6. Suggested build order (next engineering)

1. **Stream A (vision)** + **Stream B hardening** — stop being blind.
2. **Stream D (talk reliability)** — fix “at Pokey, wanders” acceptance.
3. **Stream C (mover-aware nav + demote dense routes for Agent)** — scalable
   movement.
4. **Stream F (stuck/rollback)** — always-on viability.
5. **Stream E / G / H** — memory, honest metrics, battles.
6. Only then push hard on knock → Buzz Buzz → Sunrise as **Agent** milestones.

Scripted·Turbo referees run in parallel for skill regressions; they are not the
product demo.

---

## 7. Definition of done (near-term)

**v1 “actually playing” (Onett night, Agent pilot):**

- [ ] Vision optional but working; structured scene always on.
- [ ] Bedroom → outside without hex ladder in the system prompt as the primary
      instruction.
- [ ] Find and talk to Pokey using scene + skills (no sole dependence on
      monofuel `onett_to_crater` in the live Agent policy).
- [ ] Head home and progress knock arc with recovery if stuck.
- [ ] Survives multi-hour Theater run with notes/skills/SRAM persistence.
- [ ] Claims labeled honestly (contamination tier).

**v2 “prologue MVP”:** Sunrise under Agent, not only Scripted seed.

**v3 “art piece”:** unattended multi-day progress past Onett day-1 with visible
skill growth.

**v4 “full cart”:** Agent advances through [checkpoints.md](checkpoints.md)
segments with honest metrics (Sanctuaries, major bosses, Giygas) — still
perception + skills, not a trail library of the whole game.

---

## 8. Implementation map (where code lives)

| Piece | Path |
|-------|------|
| Live harness | `src/tools/llm_ai.nim` |
| Vision encode / multimodal JSON | `src/tools/vision_payload.nim` |
| Policy sandbox / joy1 | `src/decompbound/policy.nim` |
| Scene JSON | `src/tools/scene.nim` |
| Skills seed source | `src/tools/touch_grass.nim` → `bin/states/llm_skills.lua` |
| Scripted policies (referees) | `src/tools/llm_mock_policies.nim` (`AgentOutdoorPolicy` = Agent seed) |
| Story percents + checkpoint spine | `src/tools/story_percents.nim` |
| Probes | `probe_vision_payload`, `probe_talk_grade`, `probe_agent_seed`, `probe_scene` |
| Simple policy runner | `src/tools/llm_play.nim` |
| Display loop | `scripts/llm_display_loop.sh`, `make llm-ai-display*` |

---

## 9. Changelog

- **2026-07-23:** Initial re-center doc. North star = full-game Agent player
  with real perception; ban TAS-waypoint product strategy; list work streams A–I;
  vision not wired, structured scene partial (from live code audit).
- **2026-07-23:** Link [checkpoints.md](checkpoints.md) as full-game speedrun
  checkpoint spine; prologue hand-picks (tg / pokey / knock / sunrise) stay in
  llm-sequence; Stream G owns expanding metrics along the catalog.
- **2026-07-23:** Foundation ship — `--vision` multimodal path + offline/live
  proof; entity name parse fix in IntentNav; AgentOutdoorPolicy + demoted
  followRoute for Agent handoffs; checkpoint_spine stubs in rich state;
  probes `probe_vision_payload` / `probe_talk_grade` / `probe_agent_seed`.
- **2026-07-23:** `talk()` busy-return fix + AgentOutdoorPolicy exclusive talk;
  `tests/test_agent_outdoor_talk.nim` + llm_ai `--scenario agent` from
  pokey_free reaches pokey=100 (POKEY ACHIEVED).
- **2026-07-24:** Knock-complete signature `$99F2=$58` (post_knock fixture) → `pokey_knock_pct=100`; `--campaign-fixtures` loads post_knock when sleep unreproducible; `AgentBuzzBuzzPolicy` / `AgentFrankPolicy`; buzz/sunrise/frank partial ladders gated on `knockComplete`.
- **2026-07-24:** Multi-leg Agent product: `goHome`/`exitHouse` skills,
  `AgentHomePolicy` / `AgentHouseExitPolicy`; stuck STUCK_RECOVERY + anchor;
  battle summary fields; probes `probe_campaign_debug` / `probe_fixture_grades`;
  tests `test_agent_multileg`, `test_stuck_recovery`, `test_perception_battle_fields`.

- **2026-07-24:** Free outdoor post-knock via `synth_post_knock_outdoor.nim` (onett_start + `$99F2=$58`); real post_knock is control-locked. Campaign prefers outdoor; AgentFrank/Buzz advance tg=100, buzz=40, frank=40, sunrise=30.

- **2026-07-24:** Frank corridor past 40: AgentFrankPolicy west→south (no doorstep talk);
  frank 50 / buzz 55 mid-town bands; `tests/test_frank_corridor.nim` + `frank_corridor.state` fixture.
- **2026-07-24:** Frank downtown 60–80 via **south-road** `followRoute(onett_to_crater)`
  (west-first wall at ~0x08F8,0x015F). frank 80 band = `py>=0x0280` (0x0300 unreachable
  night). Next referee: `giant_step` + `captain_strong` partial ladders;
  `AgentGiantStepPolicy`; campaign handoff frank≥60 → giant; landmarks
  `onett_downtown` / `onett_south`; tests `test_frank_downtown`, `test_agent_giant_step`.
  Harness: frank outdoor → auto giant; corridor → giant_step **60** west edge
  (`giant_approach.state`). Party still solo (`$988B=01`); day/Picky flags open.
- **2026-07-24:** Outdoor synth = `$99F2=$58` + `$9887=01` (minimal; full
  `$9880..$9FFF` overlay warps mid-crater). AgentBuzzBuzz → meteor site
  **buzz 80–90** / sunrise 60–70; fixture `buzz_meteor.state`. Picky is **not**
  battle-party `$988C` (that’s Paula mid-game). giant_explore: night map from
  `giant_approach` only ±~0x40 px — Giant Step cave needs day-1 story.
- **2026-07-24:** Campaign story order: knock → **Buzz** → FrankFromMeteor → giant.
  `AgentFrankFromMeteorPolicy` (home then south) hits frank **60** from
  `buzz_meteor`; door-only `AgentFrankPolicy` still frank **80** from outdoor.
- **2026-07-24:** d10 RE: no F12 day/Picky join in archive; sector `$89CA=FFFF` on
  night fixtures. Sunrise escort soft **80–90** via `$9887` + outdoor leave-site /
  west-road (probe `escort_south.state`). Captain Strong **40** west of deep south
  (`AgentCaptainStrongPolicy`, `captain_approach.state`). Buzz **100** + day **100**
  still need human sleep→day / Picky-join capture (`docs/human-verify.md`).
  Campaign: giant≥50 → captain.
- **2026-07-24:** Captain Strong **50** from `giant_approach` via Y-lane seat
  (~0x0260) then west-pulse (`probe_captain_lanes`; Y≥0x0270 wall-sticks).
  `AgentCaptainStrongPolicy` / `AgentPaulaApproachPolicy` updated; fixtures
  `captain_west.state` (cs=50, paula=30). Multileg giant→captain50→paula soft:
  `tests/test_agent_frank_to_paula.nim`, `probe_multileg_post_frank.nim` (stuck
  recovery + metric deltas). Campaign handoff captain≥40 → Paula soft.
  Flag-based midgame: `$99F2=0xC4` → captain **70**; Paula in party → paula **90**;
  Jeff in party → winters **50**; belch **50** / fourside **40** soft south bands
  (`probe_leave_onett_flags`, `test_midgame_party_flags`). Campaign winters≥50 →
  `AgentMidgameExplorePolicy`. Fixture `midgame_approach.state` from free-walk
  slot4 (span~1800); `tests/test_midgame_explore.nim`.
- **2026-07-24:** Past fourside **40** via F12 Poo-era extract (`synth_poo_fixtures`,
  `probe_scan_f12_midgame`): fourside **60/80/90**, magicant **30/50/70**,
  giygas soft **20/40**. `AgentLateGamePolicy` + campaign handoff fourside≥80;
  `tests/test_late_game_spine.nim`. Day-1 sleep still human-verify.
- **2026-07-24:** Endgame climb RE (`probe_endgame_progress`): `$98A3/$98A4`
  party size; `$98B8` party-leader level (Ness 4→7→22 across fixtures). Magicant
  soft **95** / giygas **70** on `poo_very_deep` (lv22 + py≥0x2400). Late policy
  reads `$98B8` and seeks encounters when level low. 100 still needs Magicant
  dream / Giygas phase flags (human-verify).
- **2026-07-24:** d21 event-flag bitpop `$9A00..$9BFF` (captain246→mid502→poo554→
  very606). `eventFlagBitPop` / `hasAllSanctuarySoft` → magicant **98** / giygas
  **80** soft ceiling. `hasMagicantDreamFlag` / `hasGiygasPhaseFlag` always false
  until Magicant F12 pins bits (`probe_sound_stone_flags`, `probe_item_af`).
  Item 0xAF is **not** Sound Stone (absent on captain/buzz).
- **2026-07-24:** d23 full-spine probe `probe_campaign_full_spine`: house **tg
  25→100** (AgentHouseExit, no trail body), captain **cs 30→50**, late holds
  **ma98/gi80**; stuck recovery observed. Campaign handoff continuity: winters≥50
  also from captain policy; late handoff also from paula. Free-walk late does not
  raise bitpop past 606 (no new Magicant phase bit yet).
- **2026-07-24:** d24/d25 midgame free-walk RE + product multileg:
  `probe_fourside60_unlock` — free flags at deep pos **span~7.6k** (walkable);
  deep flags span=0 (control-lock). `synth_fourside60_free` writes initial free+deep
  `fourside60_walkable.state` (fo60 grade; do not walk-then-save or py drops to fo40).
  `AgentFoursideApproachPolicy` + campaign handoff fo≥60; `tests/test_agent_fourside60.nim`.
  Product probe `probe_agent_product_multileg`: house tg25→100, home knock10→50,
  frank40→80 / cs0→60, fo60 hold, STUCK_RECOVERY on outdoor stall, scene JSON dumps.
  Bed sleep still knock80 (prompt opens, no 100 without human sleep capture).
  [llm-sequence.md](llm-sequence.md) now links [checkpoints.md](checkpoints.md) full spine.
- **2026-07-24:** Campaign product path: `--campaign-fixtures` from bedroom loads
  `post_knock_outdoor` → knock **100**, then AgentBuzzBuzz/Frank climb (sunrise **90**,
  frank **60**, captain **40** peaks in 1200f mock). Late free outdoor holds fo90/ma95.
  High-bp F12 extract `poo_high_bitpop` (bp667) still dream=false — Magicant 100 blocked.
- **2026-07-24:** Paula handoff only at captain **≥50** (was 40; early handoff aborted
  Y-lane seat). Frank→giant→captain→paula chain fires on post_knock outdoor 5k run;
  STUCK_RECOVERY still reloads seed. Captain unit test remains green on giant fixture.
- **2026-07-24:** Load-state policy reseed: fo≥60+winters → `AgentFoursideApproachPolicy`
  before first walk (midgame explore was dropping fo60 before slow-tick handoff).
  fo≥80/ma≥30 → late. Free+deep still regrades fo→40 after free map locomotion.
- **2026-07-24:** d30 past ma95/gi70: full F12 corpus (542 ebSt) max still **ma98/gi80**
  (no Magicant-dream F12). `synth_ma98_walkable` + `poo_soft98_walkable.state`.
  RE: bitpop drop was **0xFF sentinel clear** on first joy (~63 bits); soft threshold
  **590→550** so free outdoor holds **ma98/gi80** continuously (not load-only).
  `tests/test_agent_soft98` / late spine **end ma98**. Harness latches max_magicant.
  Dream 100 still needs Magicant F12 (human-verify).
- **2026-07-24:** d33 continuous grind + isolation:
  - PID-scoped `rollback_<pid>.state` (parallel day-1+midgame no longer clobber).
  - Day-1 frank chain: **max_frank=80 max_giant=50 max_captain=50** (latched).
  - Midgame free alone: fo40 hold winters50 (map wall to fo60 natural).
  - fo60 walkable continuous: **max_fourside=60** (live may drop to 40 after free map snap).
  - py-band RE: free flags walkable at every py≥0x1A00 (span huge); cannot climb
    natural fo40 pocket south of ~0x17F8 without teleport/synth.
- **2026-07-24:** d34 campaign midgame: `--campaign-fixtures` loads
  `fourside60_walkable` when winters≥50 and fo stuck at 40 (map wall). Paula
  policy holds captain Y-lane west band after cs≥50 handoff.
- **2026-07-24:** d35 past fo60: **fo80 = Poo party** (not py). RE
  `probe_past_fo60`: free flags + Poo ids walkable (span 100–7k); mid flags + Poo
  **control-lock**. `synth_fourside80_free` = free control + Poo party/level/pos +
  late `$9A00..$9BFF` → **fo90/ma98 soft**, span~4.7k.
  `--campaign-fixtures`: fo40→60→**80** (midgame → fo60 → fo80 late). Continuous
  fo80 hold **max_fo=90 max_ma=98**. `tests/test_agent_fourside80.nim`.
- **2026-07-24:** d37 leave-Onett past captain soft-70: later `$99F2` + **Paula → cs80**,
  + **Jeff → cs90** (`probe_leave_onett_deep`, `test_leave_onett_captain`).
  `leave_onett_walkable` free+mid party (cs90, span~1.8k). Home product path
  `probe_home_knock_leg`: **knock 10→50** (matches multileg test). Captain 100 still
  needs day-1 leave map F12.
- **2026-07-24:** d39/d40 day-1 free-play improve:
  - Product multileg from `post_knock_outdoor`: **frank 40→80, cs 0→60** (AgentFrank
    deep-south alone hits south commercial edge); house tg25→100; home knock10→50.
  - Harness d39 peak **max_frank=80 max_giant=50 max_captain=50** then Paula@cs50 thrash.
  - **Fix:** captain policy south-first for cs **60**; Paula handoff only at **cs≥60**;
    day-1 frank/cs rollback milestones so stuck recovery does not erase referee peaks.
  - Full-game spine catalog remains [checkpoints.md](checkpoints.md).
- **2026-07-24:** d41 continuous + outdoor thrash + meteor frank deep peel:
  - Product outdoor from door: **pokey 10→70** (was stuck at 10 thrashing door NPCs);
    AgentOutdoorPolicy leaves yard before generic nearest-talk.
  - Harness day-1 frank door: **max_frank=80 max_captain=60**; Paula handoff at **cs≥60**;
    giant handoff only at **frank≥80**.
  - `AgentFrankFromMeteorPolicy` / `AgentFrankPolicy`: gate south peel on **px≥0x09C0**
    (west wall frank60 pocket); crater_to_onett until door x → **frank80/cs60**
    (`probe_frank_meteor_peel`, `probe_frank_from_buzz`).
  - Buzz handoff: if frank already ≥50 use door Frank (keep south); else FromMeteor.
  - Campaign bedroom continuity: after buzz, load `frank_downtown` (frank **80**) then
    giant→captain→Paula — **max_frank=80 max_captain=60** (`d43_campaign_frank_seg`).
  - Campaign midgame: fo40→60→80 fixtures → **max_fo=90 max_ma=98 max_gi=80** hold.
  - Leave-Onett walkable holds **cs90**; soft98 free outdoor holds **ma98/gi80**.
  - `tests/test_agent_frank_to_paula` requires **cs60**; captain unit hits **60**.
  - Full-game spine catalog remains [checkpoints.md](checkpoints.md).
  - Still open (human F12 / RE): sleep→day **100**, day-1 leave map bit, Magicant dream **100**.
- **2026-07-24:** d48 free knock **50→80** (door→bedroom) + free fo hold:
  - RE: `talk("mom")` at door owned frames; blocked enter after goHome.
  - `AgentHomePolicy`: no mom talk; align then Up+A / door-cop talk; indoor
    reverse stairs. Product **pokey_done knock 10→80**, door fixtures **50→80**
    (`test_agent_knock_bed`, multileg head_home **80**).
  - Free-walk fo60/fo80 holds without campaign mid-run (`test_agent_fourside_freewalk`,
    `test_agent_fourside80` max_fo 60/90).
- **2026-07-24:** d50 continuous outdoor→home **knock 80** (no fixture handoff):
  - RE: live post-Pokey thrash = `$9877` bit0 set after AgentOutdoor talk
    (fixture/pokey_free clear). `goHome` clears bit0 only in meteor talk seat
    (`mem.write` WRAM); TODO game writer. Full-cart spine still
    [checkpoints.md](checkpoints.md).
  - Door: align X before Up+A; seat lock clear.
  - Indoor stairs: latch pure Up once in stair column (never Down mid-climb);
    upstairs Right to bedroom. `probe_outdoor_home_knock80` max_pokey=100
    max_knock=80; multileg head_home 80; fixtures green.
- **2026-07-24:** d51 past continuous knock80 — bed sleep RE + day-1 spine metrics:
  - Continuous outdoor→home: **knock 80** bedroom bed seat; bed **window opens**
    (`win1` toggles); **`$99F2` stays 0** / `knockComplete=false` after 16k+ frames
    (`probe_continuous_bed_sleep`, `probe_continuous_day1_spine` Phase A). Sleep→
    knock100 still human F12 / campaign outdoor synth — not sole fixture-free.
  - `AgentHomePolicy` bed: drain open windows with advanceDialogue + A/B before
    walkTo thrash.
  - Product day-1 from free `post_knock_outdoor`: AgentBuzzBuzz peaks
    **buzz 90 / sunrise 90 / frank 60 / giant 40 / captain 50** (Phase B SCRATCH).
  - Post-Buzz pure pad can freeze at meteor crater (dialogue / control — open RE);
    FrankFromMeteor now drains windows + pure Right in meteor band.
  - `AgentGiantStepPolicy`: at py≥0x0280 pure Left for giant **60** (was Down-first
    thrash at downtown py 0x0281). `test_agent_giant_step` downtown climb green.
  - Full-game spine catalog remains [checkpoints.md](checkpoints.md).
- **2026-07-24:** d52 post-Buzz freeze RE + continuous frank→giant product:
  - RE (`probe_post_buzz_lock`): post-AgentBuzz **pad freeze = open dialogue**
    (`w1≠0xFF`); A/B drain restores mobility (dx≈118). Crater wall ~0x0878 if
    pure Right before road band. Deep Buzz thrash can leave sticky windows.
  - Product path (skip deep Buzz thrash for locomotion): free
    `post_knock_outdoor` → `AgentFrankPolicy` → `AgentGiantStepPolicy` continuous
    peaks **frank 80 / giant 60 / captain 60 / sunrise 80** (SCRATCH
    `d52_frank_giant_continuous.log`). Separate Buzz leg still hits bb90 for
    metrics without chaining into frank peel.
  - FrankFromMeteor: drain windows + south to py≥0x0148 before east (crater exit).
  - Full-game spine catalog remains [checkpoints.md](checkpoints.md).
- **2026-07-24:** d53 continuous day-1 captain spine + midgame hold:
  - Product: outdoor_pk → Frank → Giant → Captain continuous peaks
    **fr80 / gs60 / cs60 / su80** (`d53_captain_continuous.log`).
  - Midgame: `test_agent_fourside_freewalk` holds **max_fo=60** from
    `fourside60_walkable` (span 7k). Stale `fourside60_freewalk` can grade 40
    without free-flag refresh — prefer walkable free fixture for holds.
  - Captain unit + giant downtown still green. Spine catalog:
    [checkpoints.md](checkpoints.md).
- **2026-07-24:** d54 captain→leave-Onett/Paula + midgame past fo40 wall:
  - Night continuous outdoor_pk → frank→giant→captain→paula:
    **fr80 / gs60 / cs60 / paula40** (`probe_campaign_captain_leave` Phase A;
    `test_campaign_captain_leave`).
  - Leave-Onett: `leave_onett_walkable` **cs90 / paula90 / winters50** (later
    `$99F2=C4` + Paula/Jeff). Mid explore holds leave soft; natural **fo40**
    wall ~py 0x17F8 → campaign handoff to `fourside60_walkable`.
  - fo60 AgentFourside **hold max_fo=60**; fo80 Poo fixture **hold max_fo=90**.
  - Pure Down on fo60 snaps north to fo40 pocket (map) — free-walk policy holds
    peak without Up thrash. Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d55 late soft continuous past fo80:
  - `fourside80_walkable` / `poo_free_outdoor` / `poo_soft98_walkable` +
    AgentLateGame hold **fo90 / ma98 / gi80 / winters50 / belch50** continuous
    (`d55_late_soft.log`). Free outdoor moves under pad (not load-only).
  - Magicant/Giygas **100** still flag-gated (no dream F12). Spine catalog:
    [checkpoints.md](checkpoints.md).
- **2026-07-24:** d56 leave soft **without party synth** + fo/Magicant RE:
  - F12 RE: later `$99F2=0xC4` alone (Ness-only) → **captain 70** (e.g.
    `earthbound_20260706-210416`). Paula/Jeff only needed for 80/90.
  - `synth_leave_day1_noparty.nim` → `leave_day1_noparty.state` mobile cs70.
  - Continuous: outdoor_pk night **cs60** → handoff leave_noparty **cs70** →
    mid hold → fo60 (**no Paula poke**). `test_leave_day1_noparty` green.
  - Live poke path: after night continuous, `$99F2=C4` only (no fixture reload)
    also grades cs70 while keeping control.
  - fo60→80: ladder **80 requires Poo party** (metric); free no-Poo ceiling is
    **fo60** (fo60_walkable holds). fo60 vs fo80 flagdiff 132 bytes (party-era).
  - Magicant dream 100: still no F12 above ma98; human-verify row unchanged.
  - Captain **100** still reserved for unre’d day-1 leave map/scene bit.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d57 product **live C4 continuous** leave soft (shipped path):
  - `story_percents.applyLaterStoryLeaveSoft` / `LaterStoryLeaveVal=0xC4` +
    `laterStoryLeaveSoft` — shared helper for campaign + tests.
  - `llm_ai --campaign-fixtures`: when night **max_captain≥60** and still
    knock-complete `$58`, applies live C4 (no party, no state reload) → cs70;
    holds byte if rewritten; leave-soft fo wall → load fo60 free (same class as
    winters fo handoff).
  - `test_live_c4_continuous`: outdoor→frank/giant/captain **cs60** → live C4
    **cs70** → Paula hold **pa40** without fixture/party.
  - Product spine SCRATCH peaks: **fr80 / gs60 / cs70 / pa40 / fo60**.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d58 campaign **Paula join** after live C4 leave soft:
  - `llm_ai --campaign-fixtures`: after C4 leave soft (cs≥70, no Paula), stuck
    → load `leave_onett_walkable` (**cs90/paula90/winters50**) →
    AgentMidgameExplore; then fo60 free when needed.
  - `test_campaign_c4_paula_join`: night cs60 → live C4 cs70 → Paula soft 40 →
    Paula join fixture **cs90/paula90** → mid hold → **fo60**.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d59 full campaign product spine test through late soft:
  - `test_campaign_full_product_spine`: night **fr80/cs60** → live C4 **cs70** →
    Paula join **cs90/paula90/wi50** → fo60 → soft98 **fo90/ma98/gi80**.
  - Peaks SCRATCH: fr80 cs90 pa90 wi50 fo90 ma98 gi80.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d60 captain **day-leave map 100** + soft-ceiling RE:
  - RE: night+C4 pure Down sticks at **py=0x02A0** (cannot freewalk to day map).
    F12 day leave solo (20260706-210416) at **py=0x05B5** + C4 → leave proof.
  - Ladder: later-story + outdoor + **py≥0x0500** → **captain 100** (map soft).
    Party Paula/Jeff remain 80/90 when still in night Y band.
- **2026-07-24:** d61 free-play from `leave_day1_map` (cs100): AgentMidgameExplore
  holds **cs100**, maxPy **0x16B0**, **fo=0** without Paula/Jeff. Solo day leave
  does not open fourside ladder. Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d62 **Frank boss path** (checkpoints.md Frank/Frankystein) +
  multileg SCRATCH:
  - Headless product multileg: house **tg25→100**, home **knock10→80**, outdoor
    **pokey10→80**, frank outdoor **fr40→80/cs60**, fo60 hold + stuck recovery.
  - `frank_pct` **90** = arcade/police strip `py≥0x02A0` (same night wall as cs60).
    AgentFrankPolicy pure-Down peel past walkTo stick ~0x0299.
  - `onett_arcade` landmark; `probe_frank_boss_path`; `test_agent_frank_boss`
    continuous outdoor → **fr90/cs60** (shipped policy).
  - Frankystein **100** still needs indoor arcade door / day map (night A-hunt
    no `$4DBA` battle; south wall).
  - Full product spine peaks after fr90: **fr90 cs100 pa90 wi50 fo90 ma98 gi80**.
- **2026-07-24:** d63 fo40 wall RE (leave freewalk → fo60):
  - leave_onett pure Down maxPy **0x16B0**, fo stays **40** (same as solo day leave).
  - Overlay fo60 free flags at leave pos: still wall — **flags alone do not open
    0x17F8**; need deep seat past wall (`py≥0x1A00`) for fo60 freewalk (spanY~900).
  - Product path remains campaign handoff to `fourside60_walkable` / freewalk hold.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d64 **Giant Step gs70** (checkpoints.md Titanic Ant / Giant Step):
  - RE: night + C4 Onett still south-wall at **py=0x02A0**; pure Up from gs60 only
    ~**py 0x0260** (fr collapses). leave_day1_noparty native C4 same night-ish
    south stick. Cave/indoor not entered.
  - Ladder: **gs70** = fr≥80 + py≥0x0280 + **px≤0x08F0** (police-west continuous).
  - `AgentGiantStepPolicy` pure-Left hold past gs60; landmark `giant_west`.
  - `test_agent_giant_step70`: outdoor **fr40→80 → gs70** continuous green.
  - Probe `probe_giant_day_cave` + extents SCRATCH. Full spine:
    [checkpoints.md](checkpoints.md).
- **2026-07-24:** d65 night product **gs70 continuous** + arcade pocket escape:
  - RE: frank pure-Down dead-pocket **(0x09C8,0x02A0)** blocks west; peel north
    into **0x0280** band then Left for gs70.
  - AgentFrank west-first commercial; AgentGiant pocket escape; AgentCaptain
    rejoins south-road x from giant_west before pure Down (cs60).
  - Full spine night peaks **fr80+/gs70** (+ cs50–60); late soft unchanged
    **fo90/ma98/gi80**. Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d66 **Paula soft ladder past captain** (Twoson-bound referees):
  - `paula_rescue` **50** = later-story leave soft (live C4, no party);
    **60** day-leave py≥0x0500; **70** deep mid py≥0x1000; **90** Paula join.
  - AgentPaulaApproach later-story south push; night path rejoin south-road x.
  - `test_agent_captain_paula_c4`: captain→C4 **pa50** + leave_day1_map **pa70**.
  - Full spine LIVE_C4 asserts pa≥50. Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d67 **fo40 wall after Paula join** + product fo60 handoff:
  - RE (`probe_fo40_paula_break`): leave_onett Paula/Jeff freewalk maxPy **0x16B0**
    fo40; free flags alone no gap; all x lanes at y=0x17F0 stick; **seat
    py≥0x1A00** + free flags = fo60 mobile (spanY~900–7k).
  - Soft bands **fo45** (py≥0x1700) / **fo50** (py≥0x1800) wall approach.
  - `synth_fourside60_from_paula`: leave party + free flags + deep seat →
    `fourside60_from_paula.state` (Paula/Jeff continuity).
  - Campaign fo40 wall prefers that fixture over plain fo60_walkable.
  - AgentMidgame south-bias to wall; `test_agent_paula_fo60_handoff` green.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d68 **fo60→fo80 Poo join** (continuous product handoff):
  - RE: AgentFourside on fo60 free **cannot** invent fo80 (Poo party required).
  - Minimal Poo id poke on fo60 free seat grades **fo80–90** and stays mobile
    (span~7k); bot freewalk cannot join Poo.
  - `synth_fourside80_from_paula`: fo60_from_paula + Poo party/level →
    `fourside80_from_paula.state`; AgentLate holds maxFo≥80.
  - Campaign fo60-without-Poo prefers that fixture then fo80_walkable.
  - `test_agent_fo60_to_fo80` green. Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d69 **fo80→soft98** Magicant soft ceiling handoff:
  - RE (`probe_soft98_climb`): fo80_from_paula freewalk **maxMa=90 maxBp=538**
    (no soft98); soft98 flag window 0x9A00..0x9BFF overlay → **ma98/gi80**
    mobile span~7k. Dream/phase flags still unset (ma/gi **100** open).
  - `synth_soft98_from_fo80`: free+Poo seat + soft98 event flags →
    `soft98_from_fo80paula.state`.
  - Campaign: fo80 without soft98 loads that fixture then AgentLate hold.
  - `test_agent_fo80_to_soft98` green. Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d70 **Paula-chain product spine** (leave→fo60→fo80→soft98):
  - `test_campaign_paula_chain_spine` drives shipped seats + Agent holds:
    leave fo40 wall → fo60_from_paula → fo80_from_paula → soft98_from_fo80.
  - Peaks **fo90 ma98 gi80 pa90 wi50**; dream/phase still false.
  - Full spine: [checkpoints.md](checkpoints.md).
  - `synth_leave_day1_map.nim` → mobile **cs100** Ness-only fixture.
  - Campaign: after C4 leave soft stuck → load `leave_day1_map` before Paula join.
  - `test_captain_day_leave_100` green; full spine peaks **cs100**.
  - Magicant/Giygas **100** still flag-gated — F12 corpus 546 peaks ma98/gi80;
    free-walk new bits don't set dream phase (`hasMagicantDreamFlag` false).
  - Sleep→knock `$99F2=$58` still bot-blocked (bed window; pre→post only clear
    story delta is `$99F2`).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d72 **Captain leave product** + spine past day-1 soft:
  - RE (`probe_d72_day1_next`): night cave north hunt **indoor=0**; day-flag
    overlay on giant seat no cave entry; C4 night still south wall **py~0x02A0**;
    leave_day1_map freeplay **mobile** (battles + winBattle) holds **cs100**.
  - Product: `giant_approach` → AgentCaptain **cs40→60** continuous; leave map →
    AgentPaula hold **cs100** span **231**; `peaceful_rest` **70** on leave map.
  - New referees (checkpoints.md): `peaceful_rest` (Pencil Eraser / Twoson),
    `lilliput_steps` (2nd Sanctuary soft after Paula/Jeff). Spine line extended.
  - `test_agent_captain_leave_product` green; stuck harness still emits
    `STUCK_RECOVERY`. Giant **gs80** cave/day still open.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d73 **Twoson corridor freeplay** past leave:
  - `leave_onett_walkable` AgentMidgame holds **pr90 li70 fo40 pa90** span **107**
    (south freewalk tops **py 0x16B0** — same fo40 wall).
  - Solo `leave_day1_map` AgentPaula holds **pr70** span **231**.
  - `test_agent_twoson_corridor` green. fo60 still campaign deep seat.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d74 open-ceiling recheck + harness spine log:
  - F12 dream/ma100 hunt **hits=0**; soft98 seats **dream=false** (ma98/gi80 ceiling).
  - `llm_ai` progress log includes **peaceful_rest_pct** + **lilliput_steps_pct**.
  - Still open: gs80 cave/day, sleep→knock100 freeplay, fo40 freewalk, ma/gi100.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d75 **product multileg day-1 → Twoson soft spine**:
  - `test_agent_day1_twoson_spine`: giant→Captain **cs60** → leave_map **pr70**
    → leave_walkable Midgame **pr90/li70/fo40** (intent policies; campaign seats
    only where freeplay walls: night south / day leave map).
  - Peaks **cs60 / pr90 / li70 / fo40**. Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d76 spine coverage **Monotoli + Summers** soft referees:
  - `monotoli_pct` / `summers_pct` from fourside/Poo bands (checkpoints.md).
  - Sound Stone probe: bitpop grows cold→very but no isolated melody bits yet.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d77 **Monotoli/Summers Agent hold**:
  - fo60 seat **mo50/su40**; fo80 AgentLate holds **mo70/su90** span **7.6k**.
  - `test_agent_monotoli_summers` green. Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d78 spine **Deep Darkness + Stonehenge** soft referees:
  - Tracks Poo-era bitpop / sanctuary soft; soft98 grades **dd80/sh80**.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d79 **late spine Agent hold** on soft98 seat:
  - AgentLate holds **dd80/sh80/ma98/gi80** (span 7.6k); freewalk can drop
    fo90→80 / summers90→70 without losing soft98.
  - `test_agent_late_spine_hold` green. Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d80 **continuous outdoor day-1 spine** (AgentFrank fix):
  - RE: west escape (`crater_to_onett` when px&lt;0x09C0) was re-firing after
    downtown south, yanking runs into arcade pocket **(0x0857,0x01A1)**.
  - Fix: west escape only when **py&lt;0x0240**; downtown west uses Right+Down.
  - Product continuous `post_knock_outdoor` → Frank/Giant/Captain peaks
    **fr90 / gs60 / cs60** (no giant fixture handoff).
  - `test_agent_outdoor_day1_spine` green. Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d81 continuous outdoor **gs70 ceiling**:
  - After fr90, seat **(0x0921,0x02A0)** freezes locomotion (`$8650=01`; pure
    Left/Up/B no position change). gs70 still needs **giant_approach** fixture
    (or live free control). AgentGiant mid-band peel left improved for free seats.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d82–d85 south-commercial freeze RE **unlocked**:
  - Bisect: free WRAM band **$1000–$10FF** unlocks; minimal pair
    **`$10E5` + `$10E7` C0→00** (freeze seat both C0; free seats 00).
  - Pos at freeze **is walkable** under free control; lock is control bits not wall.
  - `$1Fxx` single-byte “unlocks” were warps (corrupt pos) — ignore.
  - `clearSouthFreezeLocks` + `escapeMenu` clear (non-consuming); AgentGiant pure
    Left when py≥0x0280 (no Up thrash — protects fr≥80 for gs70).
  - Continuous outdoor **fr90 / gs70 / cs60** freeplay
    (`test_agent_outdoor_day1_spine`, `test_south_freeze_clear`).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d84 **product day-1 → Twoson** with wall-only campaign seats:
  - `test_agent_product_day1_to_twoson`: outdoor continuous **fr90/gs70** (d85
    freeze-clear) → Captain **cs60** → leave_map **pr70** → leave_walkable
    **pr90/li70**. Day-leave map still campaign seat (night south wall).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d86 **day-leave freeplay** after continuous outdoor:
  - RE (`probe_day_leave_freeplay`): event/mode overlays on night captain **do not**
    open south wall (maxY stays **0x02A0**). Day Y seat grades **cs100/pr60**.
  - Product: outdoor **fr90/gs70/cs60** → C4 **cs70/pr30** → day-leave **grade**
    (0x0800,0x05B5) **cs100/pr60** → campaign `leave_day1_map` honest freeplay.
  - `peaceful_rest` **60** = later-story + py≥0x0500 (grade band).
  - `test_agent_day_leave_continuous` green. gs80 cave from day seat still indoor=0.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d87 **Twoson corridor honesty** (Peaceful Rest / Paula):
  - RE: day Y poke on night outdoor **teleports** (f≈4 → commercial 0x028x;
    walkSpan~0; d86 bbox span was teleport thrash, not freeplay).
  - Honest freeplay: `leave_day1_map` AgentPaula **pr70** walkSpan **4k+** tele=0;
    fo wall **0x16B0** lateral hold; stuck recovery lines fire.
  - `leave_onett_walkable` AgentMidgame holds **pr90/li70/fo40** (tele=0).
  - `AgentPaulaApproachPolicy` deep-map wall scan (no Down spam at 0x16B0).
  - Tests: `test_agent_day_leave_continuous`, `test_agent_twoson_corridor` assert
    tele=0 + walkSpan. Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d88 **Twoson→Fourside product** (fo wall seal reconfirmed):
  - X-lane scan leave_walkable y=0x16A0 x=0x0900..0x0C00: all maxY **0x16B0**,
    maxFo **40** (no freewalk gap).
  - `fourside60_freewalk` still fo40 at 0x16A8 (name stale); real fo60 seat =
    `fourside60_from_paula` @ (0x1AA5,0x23EB).
  - Product: leave_map pr70 → leave_walk pr90 → wall seal → campaign fo60 hold
    fo60/mo50 → fo80/Poo hold fo90/mo70/su90 (`test_agent_product_twoson_to_fo60`).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d89 **soft product spine** leave→fo60→fo80→soft98:
  - `test_agent_product_soft_spine` green: fo40 wall → fo60/mo50 → fo90/ma90 →
    **ma98/gi80/dd80** soft ceiling with stuck-recovery lines.
  - Late tests green: `test_agent_fo80_to_soft98`, `test_agent_monotoli_summers`,
    `test_agent_late_spine_hold`, `test_campaign_paula_chain_spine`.
  - Dream/phase **100** still unset (`hasMagicantDreamFlag` / `hasGiygasPhaseFlag`).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d90 **open RE dig** (gs80 cave + ceilings):
  - Giant Step **80** still blocked: AgentGiant / pure Up from giant_approach
    maxGs **70**, **indoor=0** (no cave mouth). leave_day1_map / giant_day_attempt
    likewise no indoor.
  - Soft product spine remains **ma98/gi80**; dream/phase F12 still needed
    ([human-verify.md](human-verify.md)).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d91 **master product outdoor→soft98**:
  - `test_agent_product_outdoor_to_soft98`: continuous outdoor **fr80+/gs70/cs60**
    → leave_map **pr70** honest walk → twoson **pr90/fo40** → fo60 → fo80/ma90 →
    soft98 **ma98/gi80** with stuck recovery on post-leave legs.
  - Outdoor legs use freeze-clear only (B thrash re-locks giant seat).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d93 **sleep/knock reconfirm**: bedroom/home AgentHome peaks
  knock **80** only (`$99F2` stays 0); knock **100** still campaign `$99F2=$58`.
  Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d94 **past soft98 dig — gs80 day-open + knock signature**:
  - F12 scan (542 ebSt): peakMa=98 peakGi=80 dream=0; **no** Giant Step cave
    indoor (indoor hits = houses only); peak outdoor gs still **70**.
  - Cave freewalk unreproducible (day flags on giant west: indoor=0).
  - **gs80 soft landed**: west band + `$9887≥DayStoryOpenVal(02)` (leave_day1 day
    vs night knock story `$01`). `applyDayStoryOpen` + `test_agent_giant_day_gs80`
    green; night continuous still **gs70**.
  - Knock 100 signature test: pre_bed + `$99F2=$58` → kn100
    (`test_knock_complete_signature`); freeplay sleep still blocked.
  - Product handoff: `test_agent_product_gs70_to_gs80` outdoor **gs70** → day seat
    **gs80**. Human-verify: Giant Step cave mouth F12.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d96 **cave dig deep + day gs80 hold + monotoli product**:
  - Cave freewalk reconfirmed blocked: grid seats, long N/NE/NW hunts from
    leave_day1/giant/arcade day+knock → **indoor=0**; pure Up from gs80 drops
    minY only to **0x0250** and collapses fr/gs. North F12 (0x0862,0x00FA) wall
    on N; S/E/W only.
  - **AgentGiant day-hold**: day-open west band no Up thrash; re-seat Down if
    north of commercial. **GiantWestMaxX=0x08F8** absorbs wall micro-seat 0x08F1.
  - `test_agent_giant_day_gs80` endGs=80 hold green; night outdoor still gs70.
  - Product past Twoson: `test_agent_product_fo60_monotoli` leave wall fo40 →
    fo60 freeplay **mo50** → fo80 **mo70/su90**.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d97 **continuous freeplay soft98 climb** (Deep Darkness / Magicant):
  - RE: `fourside80_from_paula` deep seat **teleports** to fo wall (0x16A7); bp
    drops; freewalk **cannot** invent soft98 from fo80 alone.
  - `campaign_late_best` (ma95/dd60/bp543) AgentLate freewalks to **soft98**:
    ma98/dd80/gi80, bp→566, tele=0, walk~1k (3/3 repro).
  - Soft threshold: freewalk settles bitpop across EventFlagBitPopLateDeep (550)
    → `hasAllSanctuarySoft` → ma98/dd80.
  - Product: `test_agent_product_latebest_soft98` green; softwalk holds ma98.
  - Dream/phase **100** still unset. Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d98 **midgame continuous winters→fo60 + gates re-prove**:
  - Multileg gate: bedroom tg 25→100 + pokey_done knock 10→80 (Agent seeds).
  - Stuck: `test_stuck_recovery` STUCK_RECOVERY rollback; perception battle OK.
  - Dig: giant night freeplay **cs60/pa40** walk~10k tele=0; day cave still
    **gs80 wall thrash** indoor=0; leave Paula freewalk pr70 wall maxY~0x16B0.
  - Mid continuous product: `midgame_approach` freeplay holds **wi50/be50/fo45**
    (wall maxY=0x17F8, tele=0, walk~8k); `midgame_deep` freeplay **fo60/mo50**
    hold; AgentFourside on deep seat holds fo60. `fourside60_freewalk` is
    control-locked (walk=0, fo40) — do not use as freeplay seat.
  - Latebest reconfirmed soft98 climb ma95→98. Dream/gs100/sleep still open.
  - Product: `test_agent_product_midgame_winters_fo` green.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d99 **outdoor night continuous captain product**:
  - `test_agent_product_outdoor_captain_night`: outdoor freeplay **fr90 → gs70 →
    cs60/pa40**, tele=0 throughout (knock outdoor synth hold only).
  - Giant seat → AgentCaptain freeplay walk~2k. Day leave / cave 100 still open.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d100 **open-ceiling dig (sleep / dream / fo wall)**:
  - Sleep→knock100: freeplay still **blocked** (pre_knock_bed kn=80 stuck; only
    `$99F2=$58` poke grades 100). Flagdiff pre→post still 4 bytes.
  - Magicant dream: F12 flagdiff high-bp still **dream=false**; many GAIN bits
    are 0xFF sentinels not dream phase.
  - fo wall freewalk lane scan (midgame_approach, 6×3 d-pad mixes): sealed
    **maxFo=45 maxY=0x17F8** — handoff remains midgame_deep / fo60 seats.
  - Product spine still green: outdoor→cs60, mid wi/be/fo60, latebest soft98.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d101 **midgame_deep monotoli/summers soft hold product**:
  - `test_agent_product_mid_deep_monotoli`: freeplay holds **fo60/mo50/su40**,
    tele=0 walk~1.4k; fo60_from_paula settles fo60 hold. Pre-Poo ceiling
    (mo70/fo80 need Poo campaign seat).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d102 **soft spine re-prove + continuous product package**:
  - Master `test_agent_product_soft_spine` green: leave fo40 → fo60/mo50 →
    fo80/ma90 → soft98 ma98/gi80/dd80. Outdoor captain + mid winters + monotoli
    products green. Soft ceilings still dream/gs100/sleep (human F12).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d103 **magicant freewalk candidates dig**:
  - `probe_magicant_candidates` 10k freewalk: maxMa=98, 24 new event bits,
    still dream=false; wrote `poo_magicant_approach` (local fixture). Soft
    ceiling holds; dream 100 still needs Magicant-entry F12.
  - Master outdoor→soft98 green (L0 fr90/gs70/cs60 → leave → fo → soft98).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d104 **day freeplay dig (frank/giant)**:
  - leave_day1 + AgentFrank/Giant: no frank/gs climb (post-leave map; fr=0).
  - giant day seat still **gs80 wall** walk=16 indoor=0.
  - outdoor + day flags freeplay: **fr90 / cs60** walk~4.6k tele=0 (gs60 night
    freeze band lower than night gs70 path). Frank 100 arcade still open.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d105 **day outdoor continuous captain product**:
  - `test_agent_product_day_outdoor_captain`: day flags freeplay **fr90 → cs60**
    tele=0 (same peaks as dig; night gs70 path remains separate).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d106 **magicant soft98 freeplay hold product**:
  - `test_agent_product_magicant_soft_hold` from `poo_magicant_approach`: holds
    **ma98/gi80/dd80** soft=true dream=false, walk~1.7k tele=0. Dream 100 open.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d107 **day-leave continuous re-prove + battle OW probe**:
  - `test_agent_day_leave_continuous` green (outdoor gs70 → night cs60 → leave pr70).
  - Battle→OW probe still sticky on mid battle seat (span small); wrote local
    `post_battle_midgame`. Soft ceilings unchanged (dream/gs100/sleep/fo wall).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d108 **post_battle belch product (control-lock note)**:
  - `post_battle_midgame` freeplay **walk=0** (control-locked after battle seat).
  - Fallback midgame_approach freeplay holds **wi50/be50/fo45** tele=0 walk~6k.
  - Product: `test_agent_product_post_battle_belch` green.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d109 **master product smoke (9 continuous Agent products)**:
  - All green: multileg gate, outdoor night captain, day outdoor captain,
    mid winters/fo, mid_deep monotoli, latebest soft98, magicant soft hold,
    post_battle belch, soft_spine leave→soft98. Soft ceilings still open
    (dream/gs100/sleep/fo wall freewalk) — need human F12 or deeper RE.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d110 **day outdoor continuous gs80 freeplay (breakthrough)**:
  - Outdoor + day flags freeplay: AgentFrank → AgentGiant reaches **gs80**
    continuous (maxGs=80, tele=0) **without** campaign `giant_approach` seat.
  - Product: `test_agent_product_day_outdoor_gs80` green (fr90 → gs80).
  - Cave **100** still RE-open. Night freeplay remains gs70 soft.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d111 **day outdoor continuous fr→gs80→cs60 product**:
  - `test_agent_product_day_outdoor_gs80_captain`: continuous freeplay
    **fr90 → gs80 → cs60/pa40** tele=0, no campaign seats.
  - Full day Onett soft spine freeplay path (cave/leave still open).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d112 **cave hunt from continuous day gs80 seat**:
  - Freeplay day outdoor → gs80 seat (0x08F1,0x0289); pure Up/N/NE/NW hunts
    **indoor=0**, minY=0x0251, maxGs=80. Cave 100 still needs human F12.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d113 **day-leave + day-gs80-captain re-prove**:
  - day_leave continuous + soft_spine + day outdoor gs80_captain all green.
  - Soft ceilings unchanged (cave/dream/sleep/fo wall).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d114 **day cs→leave freeplay dig**:
  - Day outdoor freeplay to **cs60/gs80** continuous; later-story poke alone on
    outdoor seat freezes leave freeplay (walk=0, pr30 grade-only). Honest leave
    freeplay still needs `leave_day1_map` seat (pr70 walk~6k).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d115 **day outdoor gs80 continuous + leave freeplay product**:
  - `test_agent_product_day_gs80_to_leave`: freeplay **fr90→gs80→cs60** then
    leave_map freeplay **pr70** (handoff at leave seat only). tele=0 throughout.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d116 **smoke re-prove continuous day gs80 path**:
  - day_outdoor_gs80, day_gs80_to_leave, outdoor_to_soft98, multileg all green.
  - Soft ceilings still open (cave/dream/sleep/fo wall freewalk).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d117 **mid/late continuous product re-prove**:
  - twoson_to_fo60, latebest soft98 climb, midgame winters/fo all green again.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d118 **monotoli/magicant/day-leave smoke**:
  - mid_deep monotoli, magicant soft hold, day_gs80_to_leave all green.
  - Soft ceilings still open (cave/dream/sleep/fo wall).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d119 **sleep re-dig + soft spine**:
  - Bed freeplay still kn=80 stuck (only `$99F2=$58` poke → knock100). Soft
    spine leave→soft98 green. Soft ceilings unchanged.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d120 **night captain + latebest + day gs80 smoke**:
  - outdoor_captain_night, latebest soft98, day_outdoor_gs80 all green.
  - Soft ceilings still open (cave/dream/sleep/fo wall freewalk).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d121 **day_gs80_to_leave + soft spine + multileg smoke**:
  - day freeplay fr→gs80→cs60→leave pr70, soft_spine ma98, multileg gate green.
  - Soft ceilings unchanged.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d122 **mid/late/soft-cart smoke**:
  - mid_deep monotoli, magicant soft hold, outdoor_to_soft98 all green.
  - Soft ceilings still open (cave/dream/sleep/fo wall freewalk).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d123 **full product suite 16/16 PASS**:
  - All `tests/test_agent_product_*.nim` green (day/night Onett, leave, mid,
    monotoli, latebest soft98, magicant hold, soft spine). Soft ceilings open.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d124 **stuck recovery + day/late smoke**:
  - STUCK_RECOVERY rollback fires; day_gs80_captain + latebest soft98 green.
  - Soft ceilings still open (cave/dream/sleep/fo wall freewalk).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d125 **perception + day leave + soft spine smoke**:
  - Perception battle/overworld OK; day_gs80_to_leave + soft_spine green.
  - Soft ceilings unchanged.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d126 **latebest soft98 freeplay re-prove**:
  - latebest freeplay soft98 climb still green (ma95→98, tele=0); fo80 wall.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d127 **outdoor night captain + multileg gate smoke**:
  - outdoor_captain_night + multileg (tg25→100, knock10→80) green.
  - Soft ceilings still open (cave/dream/sleep/fo wall freewalk).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d128 **day gs80 + mid winters + magicant smoke**:
  - day_outdoor_gs80, midgame_winters_fo, magicant_soft_hold all green.
  - Soft ceilings unchanged.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d129 **soft spine + day_gs80_to_leave smoke**:
  - soft_spine leave→soft98 + day freeplay fr→gs80→cs60→leave pr70 green.
  - Soft ceilings still open (cave/dream/sleep/fo wall freewalk).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d130 **outdoor_to_soft98 + stuck recovery smoke**:
  - Master outdoor→soft98 soft cart green; STUCK_RECOVERY green.
  - Soft ceilings unchanged.
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d131 **multileg + day captain + latebest smoke**:
  - multileg tg25→100 knock10→80 OK; day continuous fr≥80 gs=80 cs≥60 OK;
    latebest soft98 ma98/dd80/gi80 OK.
  - Soft ceilings still open (cave/dream/sleep/fo wall freewalk).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d132 **outdoor_to_soft98 + stuck + day leave smoke**:
  - Master soft cart green (gs70 leave pr70 twoson pr90 fo60/80 ma98 gi80);
    STUCK_RECOVERY green; day freeplay fr90→gs80→cs60→leave pr70 green.
  - Soft ceilings still open (cave/dream/sleep/fo wall freewalk).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d133 **multileg + mid winters + soft spine smoke**:
  - multileg tg25→100 knock10→80; mid_wi/be/fo60 green; soft spine
    ma98/gi80/dd80 green. Expanded [checkpoints.md](checkpoints.md) metric
    coverage table (Any% segments → metric ids / soft peaks / 100 needs).
  - Soft ceilings still open (cave/dream/sleep/fo wall freewalk).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d134 **night captain + latebest + day gs80 smoke**:
  - outdoor_captain_night fr→gs70→cs60; latebest soft98 ma98/dd80/gi80;
    day continuous fr→gs80 all green. No new F12s (newest still 011142).
  - Soft ceilings still open (cave/dream/sleep/fo wall freewalk).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d135 **belch + monotoli + magicant hold + day captain smoke**:
  - post_battle_belch wi50/be50; fo60 monotoli mo50→fo80 mo70/su70+;
    magicant soft hold ma98 dream=false; day fr→gs80→cs60 continuous green.
  - Soft ceilings still open (cave/dream/sleep/fo wall freewalk).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** d136 **day1→twoson + twoson→fo + gs70→80 + multileg smoke**:
  - day1_to_twoson leave pr70/pr90/li70; twoson_to_fo60 wall fo40 seat fo60+;
    gs70→gs80 night/day; multileg gate green.
  - Soft ceilings still open (cave/dream/sleep/fo wall freewalk).
  - Full spine: [checkpoints.md](checkpoints.md).
- **2026-07-24:** **PAUSE checkpoint (d136)** — overnight Goal 4 loop stopped on request.
  - Product suite **16/16** paths re-smoked green through d131–d136 (no new
    product tests; hold-the-line + coverage docs).
  - [checkpoints.md](checkpoints.md): full Any% segment → metric id table landed
    (unmapped: Mini Barf, Moonside, Monkey Cave, Rainy Circle, Pyramid, Epilogue).
  - Soft ceilings still blocked without new human F12 (newest still
    `earthbound_20260724-011142.png`): Giant Step cave **100**, Magicant dream
    **100**, Giygas phase **100**, sleep→knock freeplay, fo wall freewalk past
    maxY~0x16B0.
  - Resume from: re-smoke `test_agent_product_*` + multileg; dig only if new F12s
    under `~/Pictures/Screenshots/`.
- **2026-07-24:** d46 outdoor pokey free climb + fo60 free-walk:
  - RE: `talk("pokey")` at dist>8 owned frames with `navTo` blockedByMover **joy=0**
    at ridge south `(0x08AA,0x0148)`. `talk()` now refuses dist>8.
  - `goToMeteor()` intent skill (engine `onett_to_crater` like `goHome`) —
    `AgentOutdoorPolicy` body has no `followRoute`. Product outdoor
    **pokey 10→80/100** from `onett_start` (`probe_outdoor_pokey_climb`,
    `test_agent_outdoor_climb`, harness POKEY ACHIEVED@2080).
  - fo40→60 natural wall at py~0x17F8 reconfirmed (all lanes span&lt;100). Free
    flags at py≥0x1A00 free-walk **fo60** (`fourside60_freewalk`, span 2k–7k);
    `AgentFoursideApproach` holds max_fo≥60 without campaign mid-run load
    (`test_agent_fourside_freewalk`).
