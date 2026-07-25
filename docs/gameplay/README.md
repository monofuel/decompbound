# Gameplay mechanics (docs/gameplay/)

Meta-narratives about **how EarthBound actually plays**: stat mechanics,
leveling math, known bugs/glitches — the game-design layer, as opposed to the
hardware/format layer (`memory-map.md`, `sram-format.md`, `rom-format.md`).

House rule, same as everywhere in this repo: **label the evidence**. Every
claim is tagged:

- ✅ **decomp-verified** — traced in *our* ROM/disassembly/emulator, with the
  file offset / routine address cited. This is ground truth.
- 🟡 **community** — from wikis/speedrun docs (WikiBound, SDA, TASVideos,
  Starmen.net) or the official Player's Guide; plausible but not yet proven
  by our own RE. Promote to ✅ by tracing it and citing the evidence.

Cloud LLMs confabulate EarthBound details (see `docs/llm-contamination.md`),
so nothing here should be sourced from a model's memory.

## Contents

| Doc | What |
|-----|------|
| [stats.md](stats.md) | The seven stats, storage width, the 255 rollover, equipment offsets |
| [leveling.md](leveling.md) | EXP tables, level cap, the level-up routine, stat growth |
| [inventory.md](inventory.md) | 14 slots per character, equipment-as-slot-index, Escargo Express, the ROM item table |
| [known-bugs.md](known-bugs.md) | Glitches & exploits: condiment/rock-candy, stairs, check-area, … |

## Why this folder exists

1. **Co-pilot grounding (Goal 5):** the MCP server answers questions about a
   live save; those answers should cite RE'd mechanics, not lore.
2. **Emulator accuracy:** glitches double as accuracy tests — if a documented
   glitch doesn't reproduce on our emulator, one of us is wrong.
3. **Native reimplementation (Goal 3):** you can't faithfully reimplement
   mechanics you haven't written down — including the bugs, which are part of
   the game's identity (and could become opt-out compile flags).

## Related

- `docs/decompilation.md` — the data-RE hub (where offsets get *found*).
- `docs/memory-map.md` / `docs/sram-format.md` — WRAM/SRAM layout ground truth.
- `docs/bestiary.md` — enemy stat records.
- `docs/mcp-server.md` — the co-pilot that consumes this knowledge.
