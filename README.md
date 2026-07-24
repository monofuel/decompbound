# decompbound

EarthBound (SNES, US) decompilation project in **Nim**.

The long game is a Nim project that can rebuild the English US ROM
byte-for-byte — and, along the way, a real SNES emulator plus tools that make
the reverse-engineering honest and fun. Progress is one verified region at a
time; the gold ROM is always the referee.

See **`docs/goal.md`** for the full scope, ordering, and verification rules.

## Goals

| | Goal | Status |
|---|------|--------|
| **1** | 65816 assembler + disassembler + byte-exact code regions (round-trip vs gold) | **In progress** — tooling works; coverage and adoption still growing |
| **1.5** | Adoption: replace generated scaffolding with named, documented routines | **In progress** — see `docs/goal-1.5.md` |
| **2** | EarthBound-focused SNES emulator in Nim (CPU, PPU, APU, play harness) | **Mostly done** — feature-complete for practical play; more testing still welcome |
| **3** | Verified native Nim reimplementation (subsystem by subsystem under the emu) | Someday |
| **4** | LLM plays EarthBound (Lua policy harness + story milestones) | **WIP** — see `docs/llm-plays.md` / `docs/llm-sequence.md` |

**Goal 1** is still the core decomp needle: decompiled code regions must assemble
to the gold bytes. Unsupervised “match rate” without the assembler DSL does not
count.

**Goal 2** is the playable Nim SNES emulator (pixie video, slappy audio, save
states, `make play`). It is **built for EarthBound only** — not a general SNES
compatibility layer; other games are out of scope. It has been exercised through
**more than half the game** and is effectively **feature-complete** for that
work — remaining issues are mostly minor fidelity bugs and broader playtesting,
not missing subsystems.

**Goal 4** is the experimental agent track: an LLM authors Lua that drives the
emulator (landmarks, routes, battles, knock arc, etc.). Fun and useful for RE
pressure tests; not a substitute for Goal 1.

## Current state (2026-07)

- **Decomp coverage:** ~**5.70%** of the ROM is byte-exact decompiled code
  (`make compare` → `report.md`). Implemented regions are 100% exact within
  themselves; coincidental zero-fill is tracked separately and is **not**
  progress.
- Code regions ship as bank modules under `src/decompbound/generated/`
  (assembler DSL from the gold ROM via `convert_all` / tracing). Goal 1.5
  peels understood routines into named `snesAsm` modules under
  `src/decompbound/snes_src/` (registered via `adopted.nim`).
- Shared **opcode table** (`opcodes.nim`); **assembler** + **disassembler**
  derive from it; round-trip and unit tests in `tests/`.
- **Emulator:** 65816, PPU (incl. Mode 7 / HDMA color math paths used by EB),
  APU/SPC path, joypad, save-states / F12 state-screenshots, windowed player.
  Human play past mid-game is the live proof.
- **LLM-play:** two-clock harness (`make llm-ai`), Lua skills, story percents
  (touch grass → Pokey → knock → …). Still WIP; docs under `docs/llm-*.md`.
- Gold ROM (you supply it): `./bin/Earthbound (U) [!].smc`  
  sha256: `a8fe2226728002786d68c27ddddf0b90a894db52e4dfe268fdf72a68cae5f02e`

## Quick start

```bash
# Put your legally obtained US ROM at:
#   bin/Earthbound (U) [!].smc

make compare          # build decomp ROM + compare vs gold → report.md
make test             # unit suite (builds vendor/lua when needed)
make play             # windowed emulator
make llm-ai           # LLM-play harness (needs local model setup; see docs)
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
| [docs/goal.md](docs/goal.md) | Goals, ordering, verification |
| [docs/goal-1.md](docs/goal-1.md) | Goal 1 MVP (boot path as real asm) |
| [docs/goal-1.5.md](docs/goal-1.5.md) | Adoption campaign |
| [docs/decompilation.md](docs/decompilation.md) | How tracing / coverage works |
| [docs/human-verify.md](docs/human-verify.md) | Playtest checklist for humans |
| [docs/issues.md](docs/issues.md) | Known emulator / fidelity issues |
| [docs/llm-plays.md](docs/llm-plays.md) | LLM-play harness (Goal 4) |
| [docs/llm-sequence.md](docs/llm-sequence.md) | Story percent ladder |
| [docs/audio.md](docs/audio.md) | Audio / SPC track |
| [docs/delegation.md](docs/delegation.md) | Multi-agent work style |
| [docs/state-screenshots.md](docs/state-screenshots.md) | F12 screenshots that embed save-state |

External SNES references: [SNES memory map](https://en.wikibooks.org/wiki/Super_NES_Programming/SNES_memory_map),
[superfamicom.org wiki](https://wiki.superfamicom.org/),
[SnesLab quick links](https://www.sneslab.net/wiki/Official_Documentation_Quick_Links).
