# LLM-play overhaul: teach the bot to *play*, not to follow coordinates

Status: planning (2026-07-16). Owner: this is the umbrella design for a set of
improvements to the LLM-play harness (`src/tools/llm_ai.nim`, `touch_grass.nim`
skills, `story_percents.nim`). Cross-links: `docs/llm-plays.md`,
`docs/llm-sequence.md`, `docs/memory-map.md`, `knowledge/README.md`.

## Run modes — the track matrix (canonical terminology)

The end goal is an LLM **playing** EarthBound (a 30-hour, pun-and-wordplay-heavy
game). A run is defined by two orthogonal axes; a **track** = one Pilot × one
Tempo. Everything stands on the shared **Building Blocks** — the Lua skill
library (`scene`/`talk`/`followRoute`/`winBattle`/KB in `bin/states/llm_skills.lua`,
seeded from `touch_grass.nim`). Both Pilots speak that one vocabulary; that
invariant is what keeps the tracks from diverging.

**PILOT** — who authors the policy Lua each tick:
- **Scripted** — deterministic Lua we author (seed policies / a hand TAS). The
  *reference floor*: reproducible, fast, the referees run it. (flag today: `--mock`)
- **Agent** — the LLM (qwen) writes/edits the Lua live from the Building Blocks.
  The *goal*. (flag today: `--no-mock`)
- *(future rung: **Copilot** — the LLM chooses intent; Scripted blocks execute
  the mechanics.)*

**TEMPO** — the clock + observability:
- **Theater** — real-time (~60fps) + window, for a human to watch/demo. (`--speed 60`)
- **Turbo** — uncapped fps, headless, for fast iteration / CI / progress. (`--headless --speed 0`)
- **Adaptive** — the Pilot drives its own clock via `sim.setSpeed()` (fast-forward
  corridors, slow to 60 for menus/fights). A *modifier* on either; the natural
  default for a smart Agent.

The four tracks: `Scripted·Turbo` = referees/CI · `Agent·Theater` = watch qwen
play · `Agent·Turbo` = headless autonomous grind · `Scripted·Theater` = demo a
known beat.

**Division of labor** (why the Agent track is non-negotiable): Building Blocks
handle MECHANICS (nav, battle, menus, shops, dialogue-advance — all TAS-able);
the Agent handles LANGUAGE + JUDGMENT (puns, password/riddle puzzles, item
choices, when to grind/heal, story branches — a TAS can only replay a known
answer, it can't *understand* a wordplay puzzle). The KB/memory is the Agent's
long-term brain across the long run.

**CLI (shipped):** `--pilot scripted|agent` and `--tempo theater|turbo|adaptive`
map onto `--mock`/`--headless`/`--speed`; the resolved track echoes at startup
(`llm_ai TRACK: Agent·Theater`). Verified live: `Scripted·Turbo`, `Agent·Turbo`.
- ⚠️ **Turbo isn't truly display-free yet:** `llm_ai` links `libX11` via `windy`
  even headless, so `*·Turbo` can't run on a display-less server/CI. Follow-up:
  compile-time-gate the window deps so Turbo needs no X.

**HEAD HOME leg (shipped 2026-07-20):** the campaign now has the full
prologue chain — `tg100 → PokeyVisit → pokey100 → PokeyKnock (HEAD HOME) →
door(50) → bedroom(80)`. Previously there was NO `pokey100→home` handoff, so
after Pokey the bot was told to walk home via `onett_to_crater` "backwards"
(never seats — greedy at point 1, local-mins on the hill) and stayed pinned at
the crater re-mashing talk. Fixed: (1) `followRoute('crater_to_onett')` — the
verified reverse trail promoted into the skill library as its own forward
route, `PokeyKnockPolicy` converged onto it (knock convergence, now
single-sourced with the Agent); (2) the `pokey100→PokeyKnock` live handoff;
(3) `knockPhase` — once heading home, progress/rollback track `pokey_knock_pct`
(pokey_pct dropping is expected, not regression) so a door stall no longer
teleports Ness back to the crater. Verified Scripted·Turbo end-to-end, holds at
knock=80 (the RE'd cap). The knock→100 flag still awaits a human prologue-night
capture (see `pokeyKnockPercent`).

## The problem

The bot currently plays **blind**. Every LLM tick it receives a text-only
prompt (`buildStateSummary` → `realProvider`): touch_grass/pokey/... percents,
HP/PP, money, party roster, its **own** world coordinates, sector, menu flags,
frame, and the current on-screen dialogue text. That's it.

It does **not** receive:

- the **screenshot** (the rendered `frameImage` exists but is only PNG-dumped,
  never sent to the model),
- any **structured description of the scene** — what NPCs/objects are nearby,
  who they are, where the exits and landmarks are.

Because it can't see, we compensated by hand-feeding exact hex coordinates and
waypoint ladders into the system prompt (`navTo(0x0858,0x00F2)`, etc.). That
turns the "AI" into a **TAS script we wrote** — the bot presses buttons toward
numbers it was handed; it never perceives the world or learns the game. It also
made the prompt a magnet for **story confabulation** (we typed plot from memory,
got it wrong, EarthBound cloud-AI blindspot — see the memory notes).

## The fix, in one sentence

Give the bot **eyes** (screenshot + a structured scene), let it **navigate by
intent** (landmarks/NPCs, not coordinates), let it **remember** what it learns
(a markdown knowledge base), and source the **story from the game's own
dialogue** instead of our memory.

---

## The pieces

Each piece lists: goal · design · dependencies · verification · who builds it
(per `docs/delegation.md`: CEO = me, worker = grok 4.5, verify with commands).

### A. Perception — give the bot a scene (the keystone)

Two complementary channels, sent every LLM tick:

1. **Vision (screenshot).** qwen 3.6 is multimodal — send the current
   `frameImage` as a base64 PNG in an OpenAI-style `image_url` content part.
   - Plumbing: `frameImage` is already rendered (`ppu.renderSprites`); encode to
     PNG (pixie) → base64 → add as a second content part in the `messages`
     array in `realProvider`/`realProviderSnap`.
   - ✅ **Validated 2026-07-16:** the served `qwen3.6-27b@q6_k` at
     `http://10.11.2.22:1234/v1` accepts OpenAI `image_url` content parts and
     genuinely processes them (it read a screenshot and reasoned about the pixel
     art / UI). Remaining: quality check on real EarthBound frames. Note: it's a
     **reasoning model** — give `max_tokens >= 2000` or `content` returns empty
     (the answer lands in `reasoning_content`).
   - **Serving config (Azem):** loaded at **full `-c 262144` context, `--parallel 8`**
     (`-c` = per-request window, `--parallel` = concurrent slots — independent;
     see racha `AI/azem.md`). Full context means we should **relax
     `trimForLlm`** in `llm_ai.nim` (it currently squeezes everything under
     ~26k because the model *was* loaded small) and feed the rich input —
     scene JSON + image + knowledge + history.
   - ✅ **Quality (2026-07-16):** on a real EarthBound frame qwen read it
     accurately — title text ("THE WAR AGAINST GIYGAS!"), street backdrop, and
     "the party is bottom-center-left, in the road, facing rightward." Good
     enough to perceive a scene.
   - ⚠️ **Latency: ~138s for one image call** (first call, may include warmup)
     on the Strix Halo APU. This SETTLES the architecture: **the structured
     scene JSON (piece #2, sub-millisecond) is the primary per-tick channel;
     vision is a sparse supplement** — gated behind `--vision` and fired only
     on scene-change, or as an explicit "look carefully" action the bot can
     choose. Do NOT put vision on every tick. Measure *warm* latency during
     implementation (KV cache warm may be faster).

2. **Structured scene (JSON).** A compact, deterministic JSON blob built from
   WRAM each tick — this is the reliable channel and works even without vision:

   ```json
   {
     "player": {"x": "0x0A52", "y": "0x0169", "facing": "up", "room": "onett_outdoor"},
     "entities": [
       {"slot": 4, "kind": "npc", "name": "mom", "dir": "N", "dist_tiles": 2, "on_door": true},
       {"slot": 3, "kind": "npc", "name": "?",   "dir": "N", "dist_tiles": 3}
     ],
     "exits": [{"dir": "W", "kind": "road"}, {"dir": "N", "kind": "path_up"}],
     "landmarks": [{"name": "meteor_crater", "dir": "N"}],
     "on_screen_text": "[redacted dialogue]",
     "menu": {"open": false}
   }
   ```

   - Entities come from the entity table (X `$0BBE`/Y `$0BFA` arrays, slot 24 =
     player); `name` comes from **piece B** (until then, `kind`/`?`).
   - `dir`/`dist_tiles` are computed **relative to the player** — this is what
     lets the prompt say "an NPC is 2 tiles north" instead of a raw coordinate.
   - `exits`/`landmarks`: start hand-curated per known area, later derive from
     the map/collision + a small landmark table in `knowledge/places/`.
   - Built in Nim (`buildSceneJson(ctx)`), injected into the summary; also
     exposed to Lua as `scene()` so policies can branch on it.

- **Depends on:** B (for entity names). Channel #2 ships without vision.
- **Verify:** a probe prints the scene JSON for several states; eyeball that
  `mom on_door` shows up in `home_door`, Pokey shows at the crater, etc.
- **Build:** scene JSON = me/grok; vision plumbing = me (needs live endpoint
  check).

### B. Entity identity RE — "who is this slot?"

- **Goal:** a verified per-slot WRAM field that names an entity (Mom vs Pokey vs
  a random townie), so perception can label the scene. In EarthBound each
  overworld entity spawns from a sprite/TPT (text-pointer) entry — that index is
  the identity.
- **Progress:** `src/tools/probe_entity_id.nim` dumps active slots + auto-scans
  for slot-structured arrays. Confirmed from real data: in `home_door.state` the
  **door blocker is entity slot 4** at (0x0A60,0x0158). The numeric identity
  byte itself is not yet pinned (the auto-scan surfaced mostly position-derived
  arrays).
- **Method (verify, don't guess):** diff slots across states with a **known**
  cast (`pokey_free` = Pokey by Ness; `home_downstairs_night` = Mom+Tracy;
  `onett_start`), find the array that is static (position-independent), distinct
  per NPC, and consistent when the same NPC reappears; cross-check against the
  sprite/OAM and the TPT tables in ROM. Trace a writer if possible.
- **Depends on:** nothing. Feeds A.
- **Verify:** probe prints slot→name for the known states and they match who we
  know is present; door slot 4 resolves to Mom.
- **Build:** **grok worker** (focused RE grind), tight artifact-first ticket, I
  verify the diff. Add the pinned field to `docs/memory-map.md`.

### C. Intent-level navigation — verbs, not coordinates

- **Goal:** replace coord ladders in the prompt with **intent verbs** the bot
  chooses from perception; A* does the pixel-pushing underneath.
  - `goToward(landmark)` — path toward a named landmark from `knowledge/places`.
  - `approach(slot|name)` — walk up to an entity (from the scene) and face it.
  - `followRoad(dir)` / `takeExit(dir)` — move along an exit until the scene
    changes.
  - `talk(slot|name)` — approach + face + A + drain dialogue (wraps
    advanceDialogue).
  - `readSign()` / `enterDoor()` — existing doorEnter, renamed for intent.
- These are thin Lua skills over the existing `navTo`/`walkTo`/`followTrail`
  primitives + the scene. The system prompt then reads like a strategy guide,
  not a TAS: *"Pokey's up at the crater to the north — head up there and talk to
  him."*
- **Depends on:** A (scene) + B (names).
- **Verify:** referee probes (pokey/knock) still reach their percents using
  ONLY intent verbs (no coord ladder) from a seed policy — no regression.
- **Build:** me (design) + grok (skill bodies), verified against the referees.

### D. Knowledge / memory system — remember what you learn

- **Goal:** a markdown knowledge base the bot reads and writes, so the game (and
  play experience) teaches it. See `knowledge/README.md`.
- **Layout (scaffolded):** `knowledge/{npcs,enemies,places,mechanics}/*.md`,
  each with frontmatter + short facts tagged `[game]` / `[human]` / `[bot]`.
  Seeded: `npcs/pokey.md`, `npcs/mom.md`.
- **Read:** inject only entries relevant to the current scene (NPCs on screen +
  current place) into the prompt — not the whole KB. Replaces/augments the flat
  `bin/states/llm_notes.txt` dump.
- **Write:** the policy emits a typed note; the harness routes it. Evolve the
  current `-- NOTE:` parser into typed forms:
  `-- LEARN npc:pokey he takes credit for your work` → append a `[bot]` bullet
  to `knowledge/npcs/pokey.md`. Keep flat `-- NOTE:` for scratch.
- **Depends on:** nothing (works now); better with B (name → file routing).
- **Verify:** unit-test the router (note string → correct file+tag); a run emits
  a `-- LEARN` and the file gains the bullet.
- **Build:** me (router + read-injection), small and self-contained.

### E. Ground-truth story via dialogue harvesting — stop confabulating

- **Goal:** the bot learns the story by **reading NPCs**, not from our memory.
  A probe/skill walks up to each nearby entity, faces it, presses A, and
  captures the real text via `getDialogueText` (script cursor `$96C5`), then
  files it into `knowledge/`.
- **Why:** we and cloud models get EarthBound details wrong (this session: "cop"
  that's actually Mom; "Picky lost" at the wrong beat). The ROM is the only
  reliable source.
- **Depends on:** A/B help (know who you're talking to), but a coords-free
  "approach nearest entity + A + capture" works now.
- **Verify:** harvest run over a few states produces a dialogue log; spot-check
  against known lines (Mom's "[redacted]").
- **Build:** **grok worker** (walk-and-capture grind) + me verifying captures
  land in the KB with correct attribution.

### F. Dynamic objective ladder — evolve off coordinates

- **Done (interim):** `buildStateSummary` now emits a `>>> CURRENT_OBJECTIVE`
  that **advances** with the percents (fixes the "re-talk Pokey forever" loop),
  and the confabulated plot was trimmed to confirmed facts.
- **Next:** once A–C land, rewrite each objective as **intent + perception**
  ("get to the crater and talk to Pokey"), dropping the embedded coordinate
  ladders entirely. Keep the milestone/percent gating.
- **Verify:** `make llm-ai` advances past pokey without a coord ladder.

---

## Dependency order / phasing

```
B (entity identity) ─┬─> A (scene JSON + vision) ─> C (intent nav) ─> F (objective rewrite)
                     └─> D (memory: name→file routing)
E (dialogue harvest) runs mostly in parallel; feeds D.
```

Suggested sequence: **B + D-read/write** first (foundations, parallelizable) →
**A** (scene JSON, then vision once endpoint validated) → **C** → **F**. **E**
can start any time and continuously enriches D.

## Verification & doctrine (applies to every piece)

- **Verify with commands, not vibes:** `nim check` touched files; behavioral
  probes; the pokey/knock referees must not regress; `git status` audit after
  any grok run.
- **Ground truth over memory:** entity names from the identity byte, story from
  captured dialogue. No guessed flags, no invented plot.
- **Legit play:** no coordinate glitching AND no coordinate spoon-feeding — the
  bot must reach goals by perceiving + navigating, like a human.
- **Reusable Lua:** intent verbs and `scene()` are shared skills in
  `touch_grass.nim`, regenerated into `bin/states/llm_skills.lua`.
- **Delegation:** grok workers for the RE/harvest grinds with tight
  artifact-first tickets; I hold design + verification (the referee is sacred).
- **Vision is live-only:** the multimodal path can't be proven headless — flag
  for a `make llm-ai` smoke test against the real endpoint.

## Status checklist

- [x] F (interim): dynamic objective ladder; confabulation trimmed
- [x] D (scaffold): `knowledge/` schema + seeded pokey/mom
- [x] Azem: qwen3.6-27b@q6_k loaded at full 262144 ctx × 8 slots; vision confirmed
- [x] A: `buildScene`/`sceneJson` (`scene.nim`) + `probe_scene.nim`; wired into `buildStateSummary`
- [x] A: `scene()` exposed to Lua + documented in SANDBOX API
- [x] A: relax `trimForLlm` (80k/24k backstops; feed the full brain)
- [x] **B: identity byte pinned** — `$2CD6` sprite-group / `$29CA` ptr; Mom=`$0091` verified; in `memory-map.md`; `probe_entity_names.nim` (grok, verified)
- [x] **A: scene names entities** from `$2CD6/$29CA` (reads "mom, NE, 3 tiles")
- [x] **C: intent verbs** — `nearestEntity`/`approach`/`talk` (`IntentNavSkillLua`); coord-free policy reaches pokey 100 (`probe_intent_nav.nim`, grok, verified)
- [x] **E: dialogue harvester** → `knowledge/dialogue_log.md` (`probe_dialogue_harvest.nim`, grok, verified)
- [x] **D: `-- LEARN` write-router + relevant-KB injection** live in `llm_ai.nim` (`probe_memory_router.nim`, grok, verified — Mom KB block injects when she's nearby). ⚠️ import refactor to `when isMainModule` → live `make llm-ai` smoke test wanted.
- [x] **A: landmarks** in the scene (`scene.nim` `AreaLandmarks`; door shows "meteor_crater NW")
- [x] **F: objectives rewritten to intent+perception** — hex crater ladder GONE from the prompt; travel by named landmark + `talk('mom')`/`talk(slot)`. Indoor `walkTo` waypoints remain (labeled INDOOR-ONLY).
- [x] nav CHAIN verified (`probe_gotoward_chain.nim`, grok) — **NEGATIVE**: chain jams at leg 1 (`onett_road`), pokey% stuck 10. navTo/A* can't thread this terrain; sparse landmark hops fail. F prompt corrected to an honest NAV CAVEAT (don't instruct a route that stalls).
- [x] **nav SOLVED: `followRoute(name)` dense named route** (`onett_to_crater`, engine-held) — a coord-free-from-policy `followRoute("onett_to_crater")` reaches **pokey=100** (verified: 30→100 ladder, ends adjacent to Pokey). F prompt now instructs followRoute (the working method). Sparse goToward stays for short hops/approach; the dense route is how you cross the hill.
- [ ] nav: indoor landmarks + walkTo-based goToward (kill the last coord waypoints)
- [ ] A: vision plumbing into `realProvider` (image_url; `max_tokens>=2000`; live smoke test)
