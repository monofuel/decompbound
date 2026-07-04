# Goal 1 MVP: the boot path, as real assembly

The first proper milestone of the disasm/asm project, defined precisely so a
session (human or agent) can tell whether it is done.

**MVP statement:** every byte the CPU executes from power-on, expressed as
labeled mnemonics through a working assembler, round-trip verified against the
gold ROM, with zero raw byte literals left in code regions.

This is simultaneously the tooling proof (the assembler must exist and be
correct) and the first real reverse engineering (the boot path is genuinely
interesting code: hardware init, DMA memory clears, and the APU upload
handshake where the 65816 feeds the sound driver to the SPC700 — the front
door of the audio track, see `docs/audio.md`).

## Work items, in order

### 1. The opcode table (the real meat)

One declarative table covering all 256 opcodes: mnemonic, addressing mode,
operand size, M/X flag sensitivity. The assembler, the disassembler, and
(later, Goal 2) the emulator CPU core all derive from this single table so
they structurally cannot disagree.

- No hand-written mirror-image case statements anywhere.
- This table is the foundation of the entire project. It is worth being slow
  and careful here; everything else is plumbing around it.

### 2. The assembler

Structured instruction list -> bytes, derived from the table. This is the
missing half of the repo (its absence is what forced early sessions into byte
literals).

- Front-end format (Nim macro DSL vs text `.asm`) stays deferred; the core
  eats a structured instruction list (an `Instruction`-like type already
  exists in `src/decompbound/disasm.nim`).
- Must handle labels and relative branch resolution.
- Must know M/X state to pick immediate operand widths (explicit annotations
  at entry points; tracked through REP/SEP within a routine).

### 3. Rebase the disassembler onto the table

`src/decompbound/disasm.nim` works (~112/256 opcodes, M/X tracking,
control-flow tracing) but its 585-line hand-written case statement is
transcription-typo habitat. Rebase it on the shared table and complete opcode
coverage to 256.

- Fix the address-space problem while in there: one canonical mapping between
  SNES HiROM addresses and file offsets for labels and cross references
  (`JML $C08000` lands at file offset 0x8000).

### 4. Convert the five existing regions (warm-up, known ground)

Re-express `init`, `reset`, `brk`, `early`, and `subroutine_a156` as
mnemonics sourced from *disassembly of the gold ROM* — not from the existing
comments, which contain transcription errors. The 8 known mismatched bytes
(documented in `docs/goal.md`) die automatically in this step.

- Also fix the overlapping region definitions in `common.nim`
  (`BrkHandlerOffset` sits inside the reset handler range), which
  double-count bytes in stats.
- The ROM header and reset vectors stay byte/data-declared: they are data
  structures, not code. Byte-banging data is honest; byte-banging
  instructions is not.

### 5. Trace outward (the fun part)

The current regions are islands. The reset handler immediately does
`JML $C08000` (file offset 0x8000) into unmapped territory — note: reset.nim's
comment calls this "$C00080", a byte-order transcription artifact; the decoded
bytes say $C08000, confirmed by `tests/test_asm.nim`. Follow the static
control flow:
disassemble each newly reachable routine, label it, land it in source,
round-trip it. The code map grows along real control flow instead of
arbitrary offsets.

## Definition of done

- [ ] Opcode table covers all 256 opcodes; disassembler and assembler both
      derive from it.
- [ ] Round-trip property holds: `assemble(disassemble(bytes)) == bytes` for
      every traced code region, enforced in the test suite.
- [ ] Reverse fuzz passes: random valid instruction -> bytes -> disassemble ->
      same instruction.
- [ ] The full static call graph from the reset vector — every routine
      reachable through direct `JSR`/`JSL`/`JML`/`JMP`/branches — exists as
      labeled asm source and assembles byte-exact against gold.
- [ ] The frontier is explicit: computed/indirect jumps (jump tables etc.) are
      declared as TODO frontier markers, never guessed at.
- [ ] Zero raw byte literals inside code regions (lintable rule; data regions
      are exempt but explicitly declared as data).
- [ ] The 8 known transcription bugs are gone, verified by the compare
      harness reporting 100% on all implemented code regions.

## Non-goals for this MVP

- Disassembling data regions (text, maps, sprites, music sequences).
- Any emulation (Goal 2) — static tracing only; where static analysis cannot
  prove flag state or jump targets, mark the frontier and stop.
- A polished asm front-end syntax. Structured instruction lists are enough to
  hit every checkbox above.
- Chasing coverage percentage of the whole ROM. The metric for this MVP is
  the boot-path call graph being complete and round-tripped, not total bytes.
