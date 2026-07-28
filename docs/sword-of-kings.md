# Sword of Kings — RNG-manipulation tooling plan

Status: PLAN v2 (no code yet). 2026-07-27. Reviewed by grok
(SOUND-WITH-FIXES, /tmp/sword_plan_review.md); v2 folds in all fixes —
biggest one: v1 wrongly claimed the PRNG was un-RE'd. It has been adopted
and gold-gated since 2026-07-21.

## Goal

The Sword of Kings drops (community lore says 1/128 — treat as hypothesis
until the ROM says so) from Starman Super in Stonehenge Base — the worst
grind in the game. monofuel has done this grind by hand several times:
savestate before a battle, fight it, vary the number of menu inputs to
nudge the PRNG until the drop lands. Works, but eats ~2 hours and risks
over-leveling.

We want tooling that turns the grind into a short, deterministic,
**legitimately executed** manipulation: read RAM, predict, advise — never
write game state, never force the drop. The player performs the inputs on
the real game.

## Ground rules

- **ROM evidence only** (docs/llm-contamination.md). Community numbers
  (1/128) and mechanics ("menu inputs advance RNG") are hypotheses until
  verified in our ROM/decomp.
- **Cross-check quest facts against the Player's Guide PDF**
  (decompbound_secret/earthbound.pdf): only-source and
  missable-after-base-clear questions (urgency, not design).
- **Read-only tooling.** Overlay + oracle read WRAM; the harness runs on
  forked state, never the live session. No RAM pokes, no forced drops.
- **Artifacts are recipes (text) only.** F12 PNGs, .state files, and fight
  recordings derived from the commercial ROM never land in git (existing
  policy); the harness's committed outputs are recipe strings + docs.

## What we ALREADY have (verified by review, file:line in review doc)

| Piece | Where | Notes |
|-------|-------|-------|
| **The PRNG, fully RE'd** | `snes_src/rng.nim`, docs/memory-map.md:38 | Routine `$C08E9A` (56 bytes, adopted byte-exact, gold-gated by tests/test_rng.nim). Seed = 32-bit LE at WRAM **`$0024`/`$0026`**. Cold init `$5678_1234` at `$C08121`. Algorithm known (HW mul $4202/$4216, +$6D, rotate/mix). JSL-only, **59 call sites** in generated banks; known consumers incl. battle roll site `$C2008C`, ~1/16 site `$C02686`. |
| F12 PNGs embed savestates | png_state.nim (ebSt chunk) | extractState / png_to_slot convert to harness-loadable state |
| Headless replay | replay.nim + src/tools/replay.nim | Loads slot/.state + .tas; e2e byte-identical gold gate still OPEN (docs/input-replay.md:79-80) — see Layer 2 gate 1 |
| Keybinds | play.nim | F7 (TAS), F9-F12 taken; **F8 free** |
| Frame compositing | play.nim frameImage | HUD drawable pre-swap; no text font exists yet (terminal echo only) |
| MCP co-pilot | play_mcp.nim :4343 | get_party_vitals; snapshot published every **30 frames** (staleness matters for RNG) |
| EXP table + live EXP | file 0x158F51 (docs/decompilation.md:184), party_wram.nim | Overlay EXP-to-next needs no new RE |
| Writer-trace probe pattern | probe_queue_poison2.nim:94-111 etc. | Chain-wrap `snes.bus.writeHook`, stamp `c.pbr:c.pc` |

**Stale doc note:** docs/rom-emulator-tests.md:56-58 still says "TODO: RE
the RNG seed address" — obsolete, superseded by memory-map.md:38 +
snes_src/rng.nim. Do not re-open.

## What we do NOT know (this is the real Layer 0)

1. **Action → advances table.** Which of the 59 call sites fire for which
   player actions (menu open/close, cursor, overworld idle frame, NPC
   animation, battle actions, win fanfare)? Event-driven vs frame-driven
   is the make-or-break question for human-executable recipes: monofuel's
   past success with input-count manipulation suggests event-driven —
   verify, don't assume. Includes a **menu-open dwell experiment**: does
   an open menu consume RNG per frame? (Decides whether "toggle N times"
   survives human timing.)
2. **The drop decision.** Which battle-end routine consumes the drop roll,
   the comparison + real denominator, and **where the enemy table stores
   drop item + rate** (bestiary mapping has HP/PP/EXP/money but no drop
   fields pinned — docs/bestiary.md:61-64).
3. **When the roll happens.** 🟡 **Player memory (monofuel, several past
   grinds): drops are determined from RNG BEFORE the battle starts** — not
   at the final blow. Consistent with his proven method (savestate before
   the battle, vary menu-input count, then fight). If the RE confirms it,
   the manipulation anchor moves to the pre-battle overworld (toggle
   before engaging) and the fight itself doesn't matter to the roll.
   Verify by pinning where `$C24Dxx` (drop path) is called from — battle
   init vs victory flow — and/or a write-hook run on a live encounter.
4. **A callable seed stepper.** `snes_src/rng.nim` is byte-exact snesAsm,
   not a pure `advanceSeed(seed) -> (byte, seed')` API. Small explicit
   deliverable (pure Nim from the documented algorithm, verified against
   the emulator 10/10+ like the original adoption was).

## Layered plan

### Layer 0 — call-site + drop RE (grok ticket #1)

Techniques (proven, no new hook APIs):
- Chain-wrap `snes.bus.writeHook` on `$7E0024`-`$7E0027` (+ low-RAM
  mirrors) to log writer PC + count advances per action.
- Step-loop PC watch at `$C08E9A` (probe_pc_coverage pattern) to count
  *calls* independent of seed writes.
- Static: walk the 59 `JSL $C08E9A` sites in generated/ from the known
  battle roll `$C2008C` toward victory/item-grant code; RE enemy-table
  drop fields alongside.

Exit criteria: action→advances evidence table; drop routine + denominator
+ enemy drop fields documented with evidence; roll timing pinned; pure
`advanceSeed` shipped and verified. Bonus: newly-understood routines feed
the adoption pipeline.

### Layer 1 — F8 debug overlay (can land EARLY)

Seed display is nearly free — `$0024`/`$0026` are known today:
- Phase A (no Layer 0 needed): RNG seed hex + advance counter since
  battle start / last input, EXP-to-next-level. Tiny built-in pixel font
  drawn into frameImage; echo to bin/play_log.txt; off by default.
- Phase B (after Layer 0): drop forecast line ("win now → DROP: Sword of
  Kings") — blocked until roll timing (unknown #3) is pinned.

### Layer 2 — drop-search harness (the time-saver)

Automates the historical manual method headless:

1. **Start-state contract:** mid-battle **command-menu F12** (battle
   *entry* still aborts headless — the phase-3 `$5D7C` timeout, task #19;
   don't build the scan on "walk into the spawn" until that's fixed or
   disproven for Stonehenge). PNG → extractState/png_to_slot → state.
2. **Inputs:** the state + a .tas of the fight from that point; the
   manipulation variable = N RNG advances injected via a defined encoding
   (decided in Layer 0: menu toggles at menu, or direct seed enumeration
   on the pure oracle).
3. **Drop oracle (defined, not vibes):** success = Sword of Kings item id
   present in party inventory post-battle (decoded via item_table from
   the user's ROM), optionally + victory code `$5D60=$0078`. Never "the
   RNG looked right".
4. **Output:** human recipe — "toggle the menu N times, then fight."

Gates, in order:
- **Gate 1 (trust):** same state + same .tas run twice → identical WRAM
  hash + identical drop bit (closes the still-open replay gold gap
  locally before any scan).
- **Gate 2 (pure-fn shortcut validity):** the arithmetic path
  (`seed_final = advance^K(advance^N(seed0))`) is only valid if the fight
  consumes a constant K advances regardless of N — crits/damage
  rolls/AI/turn order can break that. Verify K constancy across a few N
  by full replay before trusting arithmetic; fall back to per-N replay
  (still fast headless; linear scan 0..~127, binary only on a proven
  pure oracle).
- **Gate 3 (recipe robustness):** replay the winning recipe with sloppy
  timing (extra idle frames, slow menuing) — must still drop, else the
  recipe ships with a timing caveat.

Known failure modes to check, not discover in production: post-win RNG
advances before the roll; inventory-full (goes to Escargo Express? item
lost?); multi-enemy groups rolling per-enemy; recipes cached across level
/equipment changes (mid-battle RNG use drifts — re-scan from fresh F12).

**If pre-battle determination confirms** (player-memory hypothesis above):
the harness scan simplifies enormously — no fight replay needed at all.
Load pre-battle state → apply N toggle-advances arithmetically via
`advanceSeed` → step the fixed battle-init draw sequence → read the drop
verdict. The whole 0..127 scan becomes pure arithmetic. The costs move to:
(a) RE'ing exactly how many draws battle-init consumes before the drop
draw (must be constant per formation), and (b) headless battle ENTRY
(task #19) being needed only for one-time verification runs, not the scan.

### Layer 3 — MCP tools

`get_rng_state` (seed + advance counters) and `predict_drop` (recipe for
nearest drop window). Snapshot model must handle staleness: party vitals
publish every 30 frames; RNG tools either read fresh under the existing
lock or extend the snapshot cadence deliberately.

## Grind tactics — player field notes (monofuel)

🟡 From several completed Sword grinds on real hardware (verify in ROM
where it matters, but treat as operational truth for play):

- **One-and-done, permanently missable.** Once Stonehenge Base is
  finished, the monsters inside NEVER spawn again. Starman Super exists
  in exactly ONE area of the base and is the ONLY enemy in the game that
  carries the Sword of Kings (1/128). Clear the base without the drop and
  the sword is gone for that playthrough. All tooling urgency flows from
  this: get the sword BEFORE finishing the base.
- **Why it matters (and why it's not a crisis).** The Sword of Kings is
  the ONLY weapon Poo can equip — the one critical, permanently-missable
  weapon in the game. That said, missing it is survivable: the party can
  be over-leveled and the final Giygas fight cheeses easily with
  multi-bottle rockets. The goal is hitting the story beat properly, not
  rescuing the run. (Matches the item-table RE: Poo equip quirks already
  documented in docs/decompilation.md.)
- **You can't tell Starman from Starman Super on the map.** The area
  spawns both, and the overworld sprites don't distinguish them — you
  only learn which you engaged after the battle starts. Tooling answer:
  the enemy formation (ids) is in WRAM at battle init, so the F8 overlay
  and/or MCP should announce "Starman Super present" the moment a fight
  begins — no wasted full fights against plain Starmen, less stray EXP.

- **Atomic Power Robots must be destroyed LAST.** They explode on death
  with massive damage, and with the rolling HP meter that explosion can
  land critical damage while earlier hits are still draining. Kill order
  in mixed Starman Super groups: everything else first, robots at the end
  when the explosion can be absorbed/managed.
- The rolling HP meter interaction is the general hazard: burst damage
  stacked on an already-draining meter can take a character mortal before
  healing gets a turn.
- First live Starman Super capture: F12 2026-07-27 21:00 (local only),
  seed at command menu `8B00EDC6`; state behaves identically to fixtures
  (battle-menu idle = 0 advances).

## Intended play session

1. Reach Starman Super territory; engage a battle; F12 at the command
   menu (per the start-state contract).
2. Finish that fight normally — the session .tas already recorded it.
3. Run the harness → recipe.
4. Execute the recipe live, legitimately.
5. Sword in 1-3 battles; party barely levels.

## Order of work

1. **Layer 1 Phase A** — seed overlay + counters (nearly free, useful for
   Layer 0 verification itself).
2. **Layer 0** — call-site/action table, drop RE, advanceSeed (grok
   ticket #1; everything else hangs off it).
3. **Layer 2** — harness behind its three gates.
4. **Layer 1 Phase B + Layer 3** — forecast + MCP polish.

## Layer 0 findings — advancement schedule (2026-07-27, measured)

Source: `src/probes/probe_rng_advances.nim` (headless, counts `$C08E9A`
entries + caller return addresses over scripted inputs on local states).
Pure mirror `src/decompbound/rng_oracle.nim` (`advanceSeed`) verified
against every live RNG call over hundreds of frames —
`tests/test_rng_oracle.nim`, zero mismatches.

| Action | Advances | Dominant caller | Note |
|--------|----------|-----------------|------|
| Overworld idle 60f / 180f | **0** | — | **No per-frame tick. Event-driven confirmed.** |
| Walk (60f, direction-dep) | 0-1 | `$C02823` | Likely step/encounter check; map-context dependent |
| Menu open (A) | 2 | `$C12DDB` | |
| **Open-menu dwell 120f** | **0** | — | **Dwell-safe: human timing cannot drift the count** |
| Menu cursor move | 0 | — | Free |
| Menu close (B) | 64 | `$C12DDB` | The big lever: one toggle ≈ 66 advances |
| Dialogue idle 60f | ~50 | `$C12DDB` | Text engine consumes constantly — avoid dialogue mid-recipe |
| **Battle command menu idle** | **0** (60f+120f) | — | **Dwell-safe at the decision point** |
| Battle cursor 60f | 5 | `$C12DDB` | |
| Attack + resolution (180f) | 131 | `$C12DDB`, `$C2460D`, `$C269F5`, `$C23F78`, `$C2537B` | Battle actions consume heavily — anchors prediction at the roll, not battle start |

Implications for the recipe method: monofuel's menu-input manipulation is
vindicated and quantified — advances only happen on discrete events, idle
is free everywhere that matters, and a menu open+close moves the seed a
large fixed step. Caveats: measured on specific states; counts (esp. walk
and menu close) may vary with party size/map/context — re-measure on a
Stonehenge-local state before trusting a recipe, and note the menu-close 64
came from one state's window config.

## Open questions (answered during Layer 0, not guessed)

- Real denominator + whether Starman Super's drop slot is 100%-Sword or
  itself rolled; enemy-table drop field location.
- Event vs frame advancement; menu-open dwell behavior.
- Roll timing relative to the final blow / fanfare / loot text.
- ~~Missable-after-base-clear~~ **confirmed by player memory**: base
  completion permanently despawns its monsters; Starman Super is the sole
  Sword source, in one area only. (Guide cross-check now optional.)
- Layer 0b must find WHERE the enemy formation ids live in WRAM at battle
  init — feeds the "Starman Super present?" announcement (see tactics).
