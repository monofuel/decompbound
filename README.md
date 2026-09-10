# decompbound

EarthBound (SNES, US) decompilation project in **Nim**.

The long game is a Nim project that can rebuild the English US ROM
byte-for-byte — and, along the way, a real SNES emulator plus tools that make
the reverse-engineering honest and fun. Progress is one verified region at a
time; the gold ROM is always the referee.

See **[GOAL.md](GOAL.md)** for the canonical goals, completion criteria, and
investigation loop. The current game-source target is annotated 65816 assembly;
Nim implements the tools and emulator.

## Goals

| | Goal | Status |
|---|------|--------|
| **1** | Rebuild the original ROM byte-identically | **Met; maintain** — extraction + assembly + copied residual regions |
| **2** | Understand all game code | **Early** — 36 explained assembly regions, plus further research in tools/docs |
| **3** | Understand scripting | **Partial** — text decoding and action-script machinery; complete semantics remain open |
| **4** | Understand graphics, including the game map | **Partial** — codecs and exploratory exporters; comprehensive browsing remains open |
| **5** | Understand audio | **Partial** — playback and upload/song-loader knowledge; complete driver/sequence understanding remains open |

## Current state

- **Vanilla rebuild:** `make compare` extracts the user's ROM into ignored
  `extracted/` files and rebuilds it using `manifest.json` and `asm/`. The output
  must be byte-identical. Copied bytes do not count as understood code or assets.
- **Explained regions:** the 2026-09-10 manifest contains 2,026 explained and
  reproduced bytes (0.0644% of the whole 3 MB ROM). Other knowledge lives in
  subsystem docs and tools; there is no complete code-only denominator yet.
- **Emulator:** the repo records a complete human EarthBound playthrough through
  Giygas on the Nim SNES core. Remaining fidelity issues are tracked in
  [docs/issues.md](docs/issues.md). Playability supports the research goals.
- **Supporting tools:** F12 state-screenshots, TAS replay, Lua/LLM play experiments,
  asset exporters, and an MCP co-pilot. These are tools for investigation, not
  separate top-level completion goals.
- **Asset policy:** supply your own US ROM at `bin/Earthbound (U) [!].smc`.
  Extracted assets, scripts, saves, and captures stay local and uncommitted.

Older documents may use the retired goal numbering and generated Nim bank paths.
[GOAL.md](GOAL.md) and the [phase-2 plan](docs/decompilation-phase2.md) define the
current direction. `generated/` and `snes_src/` have been replaced by the manifest
and annotated assembly; native Nim reimplementation is outside the current goals.

## Quick start

```bash
# Put your legally obtained US ROM at:
#   bin/Earthbound (U) [!].smc

make compare          # build decomp ROM + compare vs gold → report.md
make check            # nim check entrypoints + tests (compile only)
make test             # unit suite (builds vendor/lua when needed)
make play             # windowed emulator
make llm-ai           # live qwen Agent (needs local model)
make llm-ai-scripted  # deterministic seed Lua, no qwen (watch product seeds)
make llm-ai-scripted-campaign  # same + campaign seats past sleep/walls
make mcp              # Goal 5 playthrough co-pilot MCP (http://localhost:4343/mcp)
```

Other useful targets: `make help`, `make intro`, `make jukebox`, `make audio-check`.

## Rules (short)

- **No raw byte literals in code regions.** Express code as mnemonics through
  the assembler. Unknowns are declared **data** with TODOs — never fake progress
  with copied hex.
- Prefer real meaning over magic constants; magic that must land temporarily
  needs a TODO + comment.
- **Copyright hygiene:** the repo is asset-free. No ROM, save-states, SRAM,
  screenshots of the game, or dialogue dumps. The user supplies the ROM; game
  data is extracted at run time. See `AGENTS.md`.

## Docs

| Doc | What |
|-----|------|
| [GOAL.md](GOAL.md) | Goals, completion criteria, investigation loop |
| [docs/goal-1.md](docs/goal-1.md) | Goal 1 MVP (boot path as real asm) |
| [docs/goal-1.5.md](docs/goal-1.5.md) | Adoption campaign |
| [docs/decompilation.md](docs/decompilation.md) | How tracing / coverage works |
| [docs/human-verify.md](docs/human-verify.md) | Playtest checklist for humans |
| [docs/issues.md](docs/issues.md) | Known emulator / fidelity issues |
| [docs/llm-plays.md](docs/llm-plays.md) | LLM-play harness (Goal 4) |
| [docs/llm-sequence.md](docs/llm-sequence.md) | Story percent ladder |
| [docs/mcp-server.md](docs/mcp-server.md) | MCP playthrough co-pilot (Goal 5) |
| [docs/audio.md](docs/audio.md) | Audio / SPC track |
| [docs/delegation.md](docs/delegation.md) | Multi-agent work style |
| [docs/state-screenshots.md](docs/state-screenshots.md) | F12 screenshots that embed save-state |

External SNES references: [SNES memory map](https://en.wikibooks.org/wiki/Super_NES_Programming/SNES_memory_map),
[superfamicom.org wiki](https://wiki.superfamicom.org/),
[SnesLab quick links](https://www.sneslab.net/wiki/Official_Documentation_Quick_Links).
