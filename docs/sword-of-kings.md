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
- **Jeff's Spy + roll timing — RESOLVED (2026-07-27, dynamic, ✅).**
  monofuel's field account and community knowledge were RIGHT; the
  static "victory-only" analysis was wrong (its `$AA10` writer scan only
  caught the literal `STA $AA10` opcode — blind to the indexed/indirect
  init-path store; classic player-is-slot-24 trap). Dynamic proof chain,
  all from monofuel's real captures:
  1. **Bump-entry works headless** (slot230, fleeing capture): walking
     into the overworld Starman runs battle-init `$C2B6FA` at f190 and
     the `$C24DDC` drop roll at **f192 — two frames into init**, no
     fight, no victory. The roll is decided at BATTLE START.
  2. **`$AA10` is the carry slot**, filled (or zeroed on miss) at init.
     Spy's grant-tail reads it mid-battle — "steals it if they have it,"
     exactly as monofuel described.
  3. **End-to-end manipulation PROVEN** (drop_scan, 128-way): from the
     same capture, injecting **N=32** advances (32 frames dwelling in
     the B-status window) before the bump → `AA10=0x0023` = **Sword of
     kings rolled**. N=31/33 miss — single-advance precision. Formation:
     **solo Starman Super** (an early scan read "+Dept. Store Spook" —
     a mid-init ghost from a stale `$A970` slot; monofuel caught it,
     walker now dedups + probe re-verified 300f post-init). Exactly one
     hit in 0..127, matching 1/128.
  4. Corroboration (probe_drop_referee on slot200): driving that battle
     to both-enemies-dead + 400f never executed either roll site —
     consistent with the roll having fired at that battle's init before
     the F12 was taken.
  **Engage-check-flee loop is ON:** after the swirl, `$AA10` ≠ 0 means
  this enemy is carrying its drop (Spy it or win); 0 means flee and
  re-dial the seed.
- **Surprise-attack instant wins — the ideal recipe vehicle.** Starmen
  teleport around the base; bumping one right after it teleports gives a
  surprise attack (green swirl), and on a solo Starman Super that easily
  becomes an instant "YOU WIN" with no battle at all. Per monofuel, the
  Sword CAN drop from an instant win. Consequences:
  - The instant-win path has the SHORTEST, most deterministic
    overworld-seed → drop-roll distance (no turns, no damage rolls, no
    AI). Under the victory-roll model it is the perfect recipe vehicle:
    dial the seed (spinner + fine-step, see prng.md), bump the
    teleporter, done. Under start-roll models it's equally fine — fewer
    consumers, same manipulation.
  - 🟡 RE hypothesis: the duplicate roll site (`$C26451` inside
    `$C261BD`, sole caller `$C0B758`) may be the INSTANT-WIN reward
    path, with `$C24DDC` the normal-victory path — would explain why two
    identical rolls exist. Verify: which site fires on an instant win vs
    a fought win.
  - Wanted capture: **F12 on the Stonehenge overworld just before
    bumping a freshly-teleported Starman** — gives the harness a
    pre-instant-win state (and battle ENTRY through the swirl may even
    work headless where normal entry aborts — worth testing).
  - Instant wins still award full EXP (30,145) — overleveling accrues
    regardless; manipulation is still what caps the kill count.
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
- **Over-leveling is not just inefficiency — it has endgame edge cases.**
  Each Starman Super kill is 30,145 EXP (table-verified), so a long grind
  can approach the level-99 cap before the end of the game. Two risks,
  tagged honestly:
  - 🟡 **Folklore (monofuel not 100% sure):** Ness's special end-of-
    Magicant level-up allegedly grants bonus stats; if he's already 99
    when it fires, the bonuses are lost. Unverified mechanics — RE-able
    from ROM later if we care (find the Magicant level-up routine and
    whether it's a level grant or a direct stat grant). Counterpoint from
    the same source: 99-at-Magicant means way overleveled anyway.
  - ✅ **Real (player-confirmed):** the rock candy glitch can push stats
    past 255, and u8 storage rolls them over to ~0. Overflow is real;
    keep stats away from the 255 boundary if using that trick.
  - Tooling tie-in: this is exactly why the overlay shows EXP-to-next and
    why the ideal grind loop (flee non-carriers, Spy the carrier) awards
    zero or one battle's EXP total.
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

## Layer 0b findings — drop table + drop roll (2026-07-27, verified)

Source: `src/probes/probe_drop_table.nim` (runtime ROM decode, exit 0,
6-enemy cross-check) + hand-decoded ROM bytes (generated bank02 is
fragmented by M-flag misreads around this region — trust the probe).
Full evidence: /tmp/rng_layer0b_summary.md (session artifact).

- **Enemy configuration table:** `$D59589`, `0x5E`-byte records, id-indexed.
  Name `+0x01` (EB text), HP `+0x21`, PP `+0x23`, EXP `+0x25`, money
  `+0x29`, **drop freq `+0x57`, drop item `+0x58`**.
- **Starman Super = enemy id 68** (alt row 185, same stats): HP 568,
  PP 310, EXP 30145, $735, drop item `0x23` → "Sword of kings",
  **freq 0 → 1/128 CONFIRMED** from the ROM.
- **Drop roll:** victory-flow routine indexes the table (`$C24D7C..`),
  stores candidate item to `$AA10`, then switches on freq:
  enum 0..6 → mask `$7F,$3F,$1F,$0F,$07,$03,$01` (success = draw&mask==0,
  so 1/128 … 1/2), **freq ≥7 = always drop** (no RNG). The 1/128 draw is
  `JSL $C08E9A` + `AND #$7F` at **`$C24DDC`** (duplicate clone at
  `$C264B1`). Item granted later from `$AA10` (`$C25FFC` → `JSL $C1DD7C`).
- **Timing: victory path — now STRONGLY supported (upgraded from
  unsettled, 2026-07-27 probe_spy_roll).** The earlier community/player
  "rolled at battle start, shared with Spy" model is refuted by three
  complete enumerations: (1) ALL `STA $AA10` sites ROM-wide are on
  victory/reward paths (`$C24DA7`, `$C24EB1`, `$C2647C`); (2) the second
  roll site `$C26451` is fall-through inside victory rewards `$C261BD`
  (sole caller `$C0B758`), not a battle action; (3) battle init copies
  weakness fields but NOT `+0x57/+0x58`, and holds no roll. Dynamic
  spot-checks agree (`$AA10`=0 mid-battle; idle + A-mash hit neither roll
  site). Last-mile referee (also needed for recipes anyway): drive
  slot200 to an actual win and watch `$C24DDC`/`$C264B1` fire + count K
  advances from final command menu to the draw. Pre-battle manipulation
  stays valid regardless: fixed script ⇒ outcome is a pure function of
  the pre-battle seed.
- **⚠ Open discriminator — Jeff's Spy.** With a victory-time roll, the
  remembered "Spy steals it if they have it" cannot read a not-yet-rolled
  flag. Next RE target: does Spy run its OWN roll against `+0x57/+0x58`
  (each Spy = independent 1/128 on demand — would reshape the grind loop),
  or is the memory conflating something else? Until answered, the
  carry-flag model above stays 🟡 speculation.

Recipe design consequence: with battle-menu idle = 0 advances, the
strongest anchor is the LAST command menu before the killing blow —
compute the advances K from "confirm attack" to the `$C24DDC` draw for a
fixed script, then tune the seed with zero-pressure pre-battle toggles
(and possibly in-battle cursor moves) so draw`&$7F` == 0.

## Open questions (answered during Layer 0, not guessed)

- **Which roll site fires per entry type?** Live observation (225905
  capture, sword_recipe): at some dwell offsets a battle INITS but
  `$C24DDC` never runs — likely those entries route through the
  `$C264B1` clone instead (normal vs surprise/swirl entry paths would
  explain the duplicate sites). Tool must watch BOTH sites and report
  which fired; recipes must count the right draw for the entry type
  they produce.

- Real denominator + whether Starman Super's drop slot is 100%-Sword or
  itself rolled; enemy-table drop field location.
- Event vs frame advancement; menu-open dwell behavior.
- Roll timing relative to the final blow / fanfare / loot text.
- ~~Missable-after-base-clear~~ **confirmed by player memory**: base
  completion permanently despawns its monsters; Starman Super is the sole
  Sword source, in one area only. (Guide cross-check now optional.)
- Layer 0b must find WHERE the enemy formation ids live in WRAM at battle
  init — feeds the "Starman Super present?" announcement (see tactics).
