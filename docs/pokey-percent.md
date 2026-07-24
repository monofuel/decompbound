# Pokey Percent (`pokey_pct`) — spec, and the navigation tool it needs

**Status:** in progress — target corrected; blocked on real navigation tooling.
**Owner handoff:** Fable 5.
**Updated:** 2026-07-09.

The second campaign milestone after touch grass (`tg_pct`), from the prologue
ladder in [`docs/llm-sequence.md`](llm-sequence.md). **But the real deliverable
here is a general, reusable navigation subsystem** — `pokey_pct` is just its
first real test. We have a whole game to beat; per-route hardcoded waypoints do
not scale. Build the pathfinder once, use it for every route.

---

## 1. The milestone

`pokey_pct` = the bot **legitimately navigating from Ness's house up to Pokey and
talking to him**, graded 0 → 100.

### Game truth — GET THE TARGET RIGHT
- **Pokey Minch is OUTDOORS**, at the **meteorite crash site**, top of the hill
  **NORTH** of Ness's house. Reaching him is a **long, winding, multi-screen**
  climb (monofuel: genuinely complex pathfinding).
- **Route (ground truth from monofuel):** you **cannot** walk straight north from
  the door. From the house exit, Ness must first head **SOUTH to reach the path**,
  then follow a **long winding route WEST and UP** to the meteor. (This is why the
  earlier straight-north attempt hit a "wall" — it was the fence, and it was going
  the wrong way.) Exact waypoints to be pinned from the breadcrumb capture (§4).
- **Picky** (Pokey's brother) is a **different character INSIDE the Minch house**
  (west of Ness's).
- ⚠️ **Prior work routed to the WRONG target** — walked Ness *west into the Minch
  house* to **Picky** and scored `pokey_pct=100`. Wrong character, wrong place.
  **Never grade on the Minch interior (`px ≈ 0x1C00..0x1D00`).**

---

## 2. Why this is blocked (and what the real fix is)

`walkTo` today is **reactive only** — it presses the d-pad toward a target and
has **no idea where the walls are** (`touch_grass.nim:257`: "no collision map /
tile reader used; exact pass bit in tile word at `0x2640` unpinned"). On a
straight corridor it works; on a winding path it jams against obstacles. That
dead-end is exactly what tempted the last attempt into **frame-perfect input
glitching to clip THROUGH the fence** — illegitimate, and removed (see memory
`legitimate-play-no-glitch`).

**The robust fix, already named in [`docs/llm-plays.md`](llm-plays.md):** RE the
collision map and build **real A\*** navigation. Once the bot can answer *"is
tile (x,y) walkable on the current map?"*, pathfinding any route — this hill,
and the rest of the game — becomes a solved, reusable capability.

---

## 3. The navigation subsystem (the actual deliverable)

**Design principle:** build **reusable Lua functions that permanently solve whole
chunks of the game** — navigation, dialog-reading, menu-handling — so a model like
qwen plays at the *story* level (read the dialog, decide how to advance) instead of
mashing buttons or OCR-ing screenshots. EarthBound is very long; only robust,
reusable primitives scale. Navigation is the first such chunk. See the toolkit
philosophy + address registry in [`docs/memory-map.md`](memory-map.md).

**Foundation — give Lua full SNES *read* access.** Today the sandbox's `mem.read`
is **WRAM-only** (`policy.nim`: ROM/MMIO return 0). But the emulator already has a
full-bus reader — `cpu.read8(bus, addr)` resolves the entire 24-bit space (ROM,
WRAM, everything). Exposing a read-only full-bus binding to Lua (e.g.
`snes.read(addr)` + a **ranged** `snes.readRange(addr, len)` so scanning a tilemap
isn't thousands of calls) is a few lines, and it's what lets Lua read the ROM
map/collision tables to pathfind at all. **This is prerequisite to Layer 1.**
Keep it read-only — writes stay `pad`-only.

Four layers, bottom-up. Layer 1 is the keystone; everything else is standard once
it exists.

1. **Walkability query — RE the collision / "pass" bit (KEYSTONE).**
   EarthBound builds the overworld from a tilemap (`docs/decompilation.md`:
   tilemap data at file `0x101800`, 2-byte words; ptr table `0x100000`; sectors
   are 8-byte records keyed by sector ID `$89CA`). The per-tile **passability bit
   lives in the tile word but is not yet pinned** (the `0x2640` note in
   `touch_grass.nim`). **Pin it empirically with the emulator:** walk Ness into
   known walls vs. open ground, read the tile word at the player's tile in each
   case, and find the bit(s) that flip solid↔walkable. Deliver a
   `isWalkable(snes, tx, ty) -> bool` over the live map. (`src/tools/map_explore.nim`
   already reads map data — start there.)
   - *Note:* `sector` (`$89CA`) reads `0xFFFF` in our loaded `bedroom`/`onett`
     states — confirm whether that's a save-state restore gap before relying on
     sector for anything.
2. **A\* pathfinder.** Grid search over `isWalkable` from Ness's tile to a goal
   tile. Returns a tile path.
3. **Path → inputs (reactive).** Convert the path to d-pad presses; re-plan when
   pushed off-path or blocked by a moving NPC. **No glitch fallback** — blocked
   means blocked, report it.
4. **Map/sector transitions.** Multi-screen routes cross map/sector edges via
   doors/warps (`docs/decompilation.md` has partial door/warp + sector RE). Model
   the exits so A\* can route across screens, or chain per-screen A\* at known
   transition points.

This subsystem is **game-general**. It graduates into its own `docs/navigation.md`
once built; `pokey_pct` is the first milestone that exercises all four layers
(the hill needs 1–4; short indoor hops only need 1–3).

---

## 4. Ground truth: human breadcrumb = test oracle + milestone positions

The breadcrumb trail is **validation, not the mechanism.** monofuel plays the
real game — walk Ness from the front door up to Pokey at the meteor, leaving:
- an **F12 screenshot-savestate at each bend** (exit, each turn, crest, meteor,
  beside Pokey), and
- optionally the **input sequence**.

Uses (player = entity **slot 24**; memory `player-is-slot-24`):
- **Validate the pathfinder:** the A\* route must stay within the walkable
  corridor the human actually used — catches "walks into walls" and "glitches
  through walls" regressions.
- **Pin milestone positions:** Pokey's *real* meteor coords + map → so
  `pokey_pct=100` grades on the right entity (this is the structural fix for the
  Picky-vs-Pokey class of bug).

Store states privately in `decompbound_secret/states/` (see
[`docs/state-screenshots.md`](state-screenshots.md)).

---

## 5. Metric correctness (independent of navigation)

- **No real map-id gate today.** Grading is position-only; EarthBound interiors
  reuse coordinate ranges, so `(x,y)` can collide across maps (how Picky passed
  for Pokey). Gate on a real map/area byte — find one (sector `$89CA` is `0xFFFF`,
  currently unusable). `currentRoomLabel`/`touchGrassPercent` are `tg%`-derived
  and map-blind (they label the Minch interior `outside_onett`).
- **No "talked to Pokey" flag found.** Event block `0x988B..` is unchanged before
  vs. after the (wrong, indoor) talk. RE a real met-Pokey / dialogue-complete bit
  at the *correct* meteor encounter; fallback = adjacency-to-Pokey + open dialogue
  window (`$8650 != 0xFF`).
- **Story-gating unconfirmed.** Whether the meteor is reachable from
  `bedroom.state` (vs. a cop / "go home" trigger) is unknown — the last attempt's
  "hard wall" was a fence it was cheesing, not a proven gate. Ground truth (§4)
  settles it.

---

## 6. What to keep vs. redo

**Keep (verified this session):**
- ✅ House-exit hang fix — commit `eb93a14` (save-state v2 timers). Unblocked
  loaded-state room transitions. See [`docs/play-regressions.md`](play-regressions.md).
- ✅ Harness rollback fix (`llm_ai.nim`): story-percent gains count as progress →
  no false stuck-rollback while approaching a target.
- ✅ `advanceDialogue` window gate (`$8650`) — no A-spam on open overworld.
- ✅ Log-spam trims (`llm_ai.nim`, `touch_grass.nim`).

**Redo (wrong/illegitimate):**
- ❌ Minch/Picky route + any `0x1C00` grading (`story_percents.nim`,
  `llm_mock_policies.nim`).
- ❌ `hillClimbNorth` terrain-glitch (`touch_grass.nim`) — **remove entirely.**

---

## 7. TODO (handoff checklist for Fable 5)

**Navigation subsystem (the real work):**
- [x] **Give Lua full-bus read access** — DONE 2026-07-09: `snes.read(addr)` +
      `snes.readRange(addr, len)` in `policy.nim` (side-effect-free peek; MMIO
      ports return 0). Writes stay `pad`-only.
- [x] **Pin the passability bit** → DONE 2026-07-09, and better than expected:
      collision is a **live WRAM page at `$7EE000`**, blocked iff
      `(byte & 0xD0) != 0`, probed by `$C05F33` / gated at file `0x0029CC`.
      Verified vs live movement 4/4 directions (`probe_walkable.nim`). Full
      formula in `docs/memory-map.md` + `docs/decompilation.md`. Caveat: the
      page wraps mod 64 tiles and its loader is unpinned → plan locally,
      re-plan while moving.
- [x] **A\* pathfinder** — DONE 2026-07-09: `navFindPath` in `policy.nim`,
      **pixel-space** BFS (1px steps) gated per-pixel by the exact game walk
      test. Pixel planning is load-bearing: tile-center sampling cannot thread
      the narrow `01/03` slope corridors. Lua: `nav.findPath` / `nav.walkable`.
- [x] **Reactive path→input** — DONE 2026-07-09: `NavSkillLua` → `navTo(tx,ty)`
      follows waypoints, re-plans on stuck/off-path/timer/room-jump, holds BOTH
      d-pad axes (slope tiles only move on diagonal input), honest BLOCKED
      report, no glitch fallback. Verified door→crest 445 frames (probe_navto).
- [ ] **Map/sector transition** model for multi-screen routes (doors/warps) —
      only if route discovery shows the meteor route needs one.
- [ ] Graduate the subsystem into `docs/navigation.md` once it works.

**Pokey milestone (uses the subsystem):**
- [ ] Remove `hillClimbNorth` glitch + Minch/Picky grading.
- [ ] Capture ground truth (monofuel): play house → Pokey, drop savestates +
      input log to `decompbound_secret/states/`. **Queued in
      `docs/human-verify.md` 2026-07-09** — audit of all 365 existing secret
      states found no house→meteor trail (closest: a west yard corridor at
      `py≈0x16xx`). Nav work proceeds on emulator-discovered route meanwhile.
- [ ] Validate A\* route against the breadcrumb corridor; pin Pokey's real coords.
- [ ] Regrade `pokeyPercent` on the real outdoor meteor target, gated on a real
      map/area byte; RE a "talked to Pokey" flag (fallback: adjacency + window).
- [ ] Resolve story-gating (is the meteor reachable from `bedroom.state`?).
- [ ] Verify legit end-to-end: `pokey_pct` 0 → 100 with logged `(x,y)` proving
      Ness walked (not clipped) to Pokey at the meteor.

---

## 8. References

- Campaign ladder: [`docs/llm-sequence.md`](llm-sequence.md) · Harness:
  [`docs/llm-plays.md`](llm-plays.md) (already defers "real A\* once we RE the
  collision map")
- Map/collision RE: [`docs/decompilation.md`](decompilation.md) (tilemap
  `0x101800`, sectors `$89CA`), [`docs/graphics.md`](graphics.md),
  `src/tools/map_explore.nim`
- Hang fix / baseline: [`docs/play-regressions.md`](play-regressions.md) (commit
  `eb93a14`; baseline `0bdad72`)
- Savestate format: [`docs/state-screenshots.md`](state-screenshots.md)
- Code: `src/tools/story_percents.nim`, `src/tools/llm_mock_policies.nim`,
  `src/tools/touch_grass.nim`, `src/probes/probe_pokey_*.nim`
- Memory: `legitimate-play-no-glitch`, `player-is-slot-24`
