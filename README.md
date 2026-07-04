# decompbound

Earthbound (SNES) decompilation project in Nim.

The goal of this project is to build a Nim program that can eventually reproduce the Earthbound English US ROM exactly.
This will be a very long and complex project. we just need to push the needle forward one byte at a time.

See `docs/goal.md` for the full scope, ordering, and verification rules. Short version:

1. **Goal 1 (current):** a 65816 assembler + disassembler pair in Nim, derived from a single opcode table, verified by round-tripping the gold ROM's code regions.
2. **Goal 2 (later):** an Earthbound-specific SNES emulator in Nim (pixie video) to close the loop — dynamic tracing for the disassembler, differential testing gold vs decomp.
3. **Goal 3 (someday):** a verified native Nim reimplementation, migrated one subsystem at a time under emulator differential tests.

store the comparison rom at `./bin/Earthbound (U) [!].smc`
- sha256sum: `a8fe2226728002786d68c27ddddf0b90a894db52e4dfe268fdf72a68cae5f02e  bin/Earthbound (U) [!].smc`

## current state (2026-07-03)

- the compare harness works and writes `report.md`.
- **implemented regions: 100% matched** (141,964/141,964 bytes incl. header —
  4.5% of the ROM, every traced code region).
- code regions are generated wholesale by `src/tools/convert_all.nim`: it
  traces the ROM from its interrupt vectors and emits one assembler-DSL
  module per code region into `src/decompbound/generated/` (266 modules,
  ~66k instructions), with entry flag states the tracer actually observed.
- regions live in a central registry (`src/decompbound/regions.nim`) shared by
  the ROM builder and the compare harness; boundaries follow the control-flow
  tracer's natural code regions, not arbitrary cuts.
- the remaining 95% of the ROM is data (text, maps, sprites, music) plus code
  reachable only through computed jumps — the current static-tracing frontier.
- the shared opcode table exists (`src/decompbound/opcodes.nim`, all 256
  opcodes); the assembler (`assembler.nim`) and disassembler (`disasm.nim`)
  both derive from it. Round-trip + gold ROM tests in `tests/`.
- all code regions are expressed as mnemonics generated from gold ROM
  disassembly (`src/tools/gen_source.nim`); the 8 transcription bugs from the
  byte-literal era are fixed. Header + vectors remain data declarations.
- HiROM address mapping in `memmap.nim`; static tracing from the reset vector
  discovers ~142KB of code (`src/tools/full_disasm.nim`).
- next (goal-1.md work item 5): trace outward and convert the discovered
  boot-path code, region by region.
- exploration tools in `src/tools/` (disasm, full_disasm, gen_source,
  map/sprite/music/sound explorers).

## testing

- `nim r src/decompbound.nim --compare`
  - this will generate a decomp rom at `./bin/Decompbound.smc` and compare it to the gold master rom.
- `nim r src/decompbound.nim` simply generates a decomp rom.
- `nimble test` runs the test suite.

## rules

- **no raw byte literals in code regions.** code must be expressed as
  mnemonics through the assembler (once it exists). if bytes can't be
  expressed that way yet, declare the region as data with a TODO — never
  hardcode "temporary" literals. this is what keeps the progress metric
  honest (see `docs/goal.md`).
- we should avoid magic bytes as much as possible and instead figure out what they are representing properly.
  - all magic bytes must be accompanied by a TODO and comments.
- all fixed assets should live in `src/assets` (music, sounds, sprites, graphics).

## bug fixes

- we can control compilation with compile time `consts` and flags.
- the default decompbound.nim should eventually get to reproducing the rom exactly.
- however we can add compiler flags for fixing bugs.

## later goals (notes)

- pixie for graphics, shady for the whacky battle background shaders — this
  belongs to the emulator (Goal 2) and native reimplementation (Goal 3), not
  the current byte-exact work.
- graphics probably as bitmaps, staying close to source material.

## Docs

- decompbound/docs/goal.md - project goals, ordering, and verification rules
- decompbound/docs/goal-1.md - Goal 1 MVP definition: the boot path, as real assembly
- decompbound/docs/goal-1.5.md - the adoption campaign: replacing generated scaffolding with understood, named code
- decompbound/docs/audio.md - SNES/Earthbound audio, the standalone SPC player track, slappy tools
- decompbound/docs/delegation.md - delegating verification-backed work to grok via agnt
- decompbound/docs/snes-asm.md
- decompbound/docs/graphics.md
- decompbound/docs/rom-format.md

- extensive docs on rom format: https://en.wikibooks.org/wiki/Super_NES_Programming/SNES_memory_map
- extensive general docs on snes stuff https://wiki.superfamicom.org/
- https://www.sneslab.net/wiki/Official_Documentation_Quick_Links
