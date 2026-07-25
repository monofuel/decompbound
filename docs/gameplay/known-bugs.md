# Known bugs & glitches

Catalog of EarthBound's documented bugs. Dual purpose: **emulator accuracy
tests** (a glitch that doesn't reproduce here means our emulator diverges) and
**mechanics documentation** for Goal 3 / the co-pilot.

Everything below is 🟡 **community** (WikiBound, SDA, TASVideos — the original
link dump lives at the bottom) unless marked ✅ with our own evidence.

## Stat & item exploits

| Glitch | Effect | Mechanism | RE status |
|--------|--------|-----------|-----------|
| **Condiment / Rock Candy** | Infinite stat boosts | Food at bottom inventory slot + condiment in bag: in battle, using the food consumes only the condiment. Sugar Packet / Delisauce double the gain. Fixed in GBA port. | 🟡 mechanism; ✅ the *rollover it enables*: stats are u8, level-up path is 8-bit ([[stats]]). TODO: trace the boost routine's missing clamp. |
| **Stat overflow** | Stat wraps to ~0 past 255 | Single-byte stats, no clamp on boosts. | ✅ storage/arithmetic width ([[stats]]); 🟡 no-clamp claim. |
| **Item duplication nuances** | Dupe items | Inventory edge cases (TASVideos). | 🟡 |

## Movement / sequence breaks

| Glitch | Effect | Mechanism | RE status |
|--------|--------|-----------|-----------|
| **Stairs / walk-through-walls** | "Ghosted" state — pass through walls, NPCs, cliffs | Interrupt a stair transition (phone call / low-HP alert / death+save manip). Exploits the single large map. | 🟡 |
| **Check Area / Threed tent** | Garbage text, warps, **debug menu** | Repeated corner "Check" at specific spots (Threed circus tent bottom-right, Onett edge) with 2P buttons held → out-of-bounds map-edge reads. | 🟡 |
| **Walk through cliffs** | Pass impassable tiles | Tile-passability exploits (TASVideos). | 🟡 |
| **Stutter-walking** | Skip triggers | Movement timing skips trigger tiles. | 🟡 |
| **Skip Sandwich / Bike Bell / Onett Barrier Skip** | Speed/sequence oddities | See SDA/TASVideos. | 🟡 |

## Battle & system

| Glitch | Effect | Mechanism | RE status |
|--------|--------|-----------|-----------|
| **Simultaneous defeat EXP underflow** | EXP corruption | Party wipe at the same instant as enemy defeat. | 🟡 |
| **Sprite overload crash** | Hard crash | >~22 sprites loaded (25+ unstable). | 🟡 |
| **Diamondized teleport** | Cosmetic diamondize-on-collision | Teleport while a member is diamondized. | 🟡 |

## Not bugs, but adjacent

- **Rolling HP meter** — mortal damage isn't applied instantly; the odometer
  rolls down and can be outraced by healing/victory. Core *intended* mechanic
  (record offsets `+$45` rolling vs `+$47` current — [[stats]]), but it
  interacts with several glitches above.

## Using these as emulator tests

The accuracy angle (see `docs/accuracy.md`, `docs/rom-emulator-tests.md`):
each mechanically-understood glitch is a candidate headless probe — set up the
trigger state, assert the glitched outcome. A glitch that *doesn't* happen on
our emulator is an accuracy bug on our side. None are automated yet.

Per the no-glitch rule for the LLM player (`docs/llm-plays.md`): these are for
*testing and documentation*, not for the bot to exploit.

## Compile-flag idea (Goal 3)

Original monofuel note: patched builds could make fixes opt-in compile flags
(e.g. `-d:fixCondimentGlitch`), keeping default behavior bug-faithful.

## Sources (community)

- WikiBound glitch list: https://wikibound.info/wiki/List_of_glitches_in_the_EarthBound_series
- SDA knowledge base: https://kb.speeddemosarchive.com/Earthbound/Tricks_and_Glitches
- TASVideos: http://tasvideos.org/GameResources/SNES/Earthbound
- Video overview: "Earthbound Glitches" by Son of a Glitch — https://www.youtube.com/watch?v=LL5QkmEClvc

## Related

- [[stats]] · [[leveling]] — the mechanics these exploit.
- `docs/accuracy.md` — emulator accuracy tracking.
