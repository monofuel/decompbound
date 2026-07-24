# Project Goals

"Reverse engineer Earthbound in Nim" is too vague to act on. This doc defines
what we are actually building, in order, and how each step is verified.

The core lesson from early attempts: unsupervised LLM sessions will game any
metric that can be gamed. The 1,990 "implemented" bytes were hand-transcribed
byte literals copied from a disassembly listing (complete with transcription
typos), not understanding. Every goal below is chosen so that progress is
mechanically verifiable and cannot be faked.

## Context

- Earthbound (SNES, US) is hand-written 65816 assembly plus large amounts of
  data: text/event scripts, maps, sprites, music. Most of the 3MB ROM is data,
  not code.
- The cart is plain HiROM + battery SRAM. No enhancement chips (no SA-1,
  SuperFX, or DSP-1).
- Because the original is hand-written asm (not compiled C), a byte-matching
  reproduction must be authored at the assembly level. High-level Nim cannot
  compile to byte-identical output; it can only mirror behavior (see Goal 2+).
- Prior art exists (community disassembly efforts, CoilSnake data format docs).
  This project is clean-room for the fun of it; the novel parts are the Nim
  toolchain and the verification methodology.

## Goal 1 (current): 65816 assembler + disassembler in Nim

A matched pair of tools derived from a single opcode table, proven by
round-tripping the gold master ROM's own code regions.

**MVP definition: `docs/goal-1.md`** — "the boot path, as real assembly."
**Follow-up: `docs/goal-1.5.md`** — the adoption campaign: generated
regions are scaffolding, to be replaced by named, documented modules
(byte-verified) until the project reads like a romhacker's dream.
Ordered work items and a mechanical definition of done live there.

### Components

- **One declarative opcode table** — all 256 opcodes: mnemonic, addressing
  mode, operand size, M/X flag sensitivity. The assembler, disassembler, and
  (later) emulator are all derived from this one table so they structurally
  cannot disagree. No hand-written mirror-image case statements.
- **Disassembler** — bytes to labeled listing. A partial one exists
  (`src/decompbound/disasm.nim`, ~112 opcodes, M/X state tracking, control
  flow tracing); it should be completed and rebased on the shared table.
- **Assembler** — instruction list to bytes. Does not exist yet; this is the
  missing half that forced early sessions into raw byte literals.
- **ROM builder** — code regions emitted via the assembler, data regions
  declared explicitly as data (assets, scripts, unknown blobs).

### Verification (the ungameable part)

- **Round-trip property:** for every region the tracer proves is code,
  `assemble(disassemble(bytes)) == bytes`. The gold ROM is the test suite.
- **Reverse fuzz:** random valid instruction -> bytes -> disassemble -> same
  instruction. Catches table errors the ROM does not exercise.
- **No raw byte literals in code regions.** Code must be expressed as
  mnemonics through the assembler. This rule is lintable and non-negotiable;
  it is what makes the progress metric honest. Data regions are exempt but
  must be explicitly declared as data.
- **Progress metric:** percent of ROM covered by round-tripped code regions
  plus declared data regions — not raw matching bytes, which zeros inflate
  (the current 13% "total match" is mostly accidental zero-matches).

### Migration

The existing hand-transcribed modules (`init`, `reset`, `brk`, `early`,
`subroutine_a156`) get re-expressed through the assembler, sourced from
disassembly of the gold ROM rather than trusted comments. Known transcription
bugs this will fix automatically (8 mismatched bytes as of 2026-07-03):

- `init.nim`: `LDA $C24D` should be `LDA $4DC2` (operand byte-swapped).
- `init.nim`: `CMP #$1080` should be `CMP #$8010`, twice (matches the
  preceding `AND #$8010` mask).
- `brk.nim`: `STY $2103` should be `STY $4300` (DMA channel 0 setup, not
  OAMADDH).
- Also fix: `BrkHandlerOffset` (0x8147) overlaps the reset handler region
  (0x8141 + 704) in `common.nim`, double-counting bytes in stats.

### Known traps

- **M/X immediate widths:** immediate operand size depends on runtime
  processor flag state. Flag state must be tracked through control flow, and
  ambiguous entry points need explicit annotations, never guesses. (Goal 2
  dissolves this: an emulator observes the real flag state.)
- **Address spaces:** the tools currently think in file offsets, but the code
  thinks in SNES HiROM addresses (`JML $C08000` lands at file offset 0x8000). Pick
  one canonical mapping for labels and cross-references.
- **DSL vs text format:** deferred. The assembler core eats a structured
  instruction list; a Nim macro DSL or a text `.asm` parser are both
  front-ends that can come later.

## Goal 2 (later): Earthbound-specific SNES emulator in Nim

An emulator scoped to running exactly one game, using pixie for video output.
This closes the verification loop: Goal 1 verifies encoding (bytes <->
mnemonics), the emulator verifies semantics (what the code does).

### Why it feeds Goal 1

- **Dynamic tracing:** executed addresses are code by definition, and observed
  flag states give correct M/X widths. The disassembler stops guessing.
- **Differential testing:** run gold ROM and decomp ROM side by side; the
  first trace divergence is the exact instruction where understanding fails.
- **Shared opcode table:** the CPU interpreter is the third derivation of the
  Goal 1 table.

### Scope notes

- No enhancement chips to emulate. Instruction-level CPU + scanline-level PPU
  accuracy should suffice; Earthbound does not race the beam.
- **HDMA is not optional** — battle backgrounds and other effects depend on it.
- **The APU handshake is not optional** — the game hangs at boot waiting for
  the SPC700's replies. HLE the handshake first (fake the replies); real
  SPC700 + DSP audio emulation is a large sub-project deferred to the end.

### Milestone ladder

1. [DONE 2026-07-04] 65816 CPU core passing per-instruction test vectors:
   5,120,000/5,120,000 SingleStepTests vectors, native + emulation
   (`cpu.nim`, `tests/test_cpu.nim`, `tools/run_vectors.nim`).
2. [DONE 2026-07-04] Memory map + DMA + interrupt vectors: the real ROM
   boots on the core (`snesbus.nim`) — WRAM clear, PPU init, sound driver
   upload, NMI-driven main loop (`tests/test_emulator.nim` pins depth).
3. [DONE 2026-07-04] APU handshake HLE incl. driver-ready and the $FF
   reboot-to-bootROM command the game uses between intro screens.
4. [MOSTLY DONE 2026-07-04] PPU rendering into pixie (`ppu.nim`,
   `tools/screenshot.nim`): modes 0/1/3 backgrounds render the boot
   sequence pixel-perfect — anti-piracy warning, APE logo, and the
   "War Against Giygas" title card. Remaining: sprites (OAM), scroll,
   HDMA effects, remaining modes.
5. Input + SRAM: SRAM done (the anti-piracy check demanded it); joypad
   auto-read next — then walk around Onett, save the game.
6. Real audio (SPC700 + DSP) integrated into the emulator. See Goal 2a below —
   the audio cores are built early as a standalone track and slot in here.

### Goal 2a: standalone SPC player (parallel track, sanctioned fun)

The APU is fully self-contained, so Earthbound music is playable via a
standalone SPC player with zero SNES emulation — no need to wait for the
emulator. Shares no code with Goal 1, so it runs in parallel without blocking
it. Full plan, components, and verification rules: `docs/audio.md`.

## The data: decompiling the other 90% of the ROM

Goal 1 conquered the boot-path **code**, but most of the 3MB ROM is **data** —
text and event scripts, graphics, music, maps, and game tables. Reverse-
engineering these formats is the bulk of "decompile EarthBound," and it is not
optional the way the companion apps are — it is the core mission the emulator
work has been quietly enabling.

Tracked as parallel data-RE tracks unified by the same honesty rule as Goal 1:
**`encode(decode(bytes)) == bytes`**, per asset, against the gold ROM. The
emulator (Goal 2) is the *instrument* that makes it tractable — it watches the
game decode its own data (VRAM DMA → graphics, APU uploads → music, the
text/event interpreters → scripts), so static disassembly stops guessing.

Full hub + tracks (graphics, audio data, scripts/events, maps, game tables):
**`docs/decompilation.md`**. This is a prerequisite for Goal 3 — you cannot
reimplement a game whose data you cannot read.

## Goal 3 (someday): verified native reimplementation

Once the emulator runs the original code, a native Nim port becomes a
ship-of-Theseus: replace one subsystem at a time with native Nim (pixie
graphics, shady shaders), differential-testing each swap against the emulated
original. Not a rewrite — a gradual, verified migration. Nothing here should
be started until Goals 1 and 2 provide the harness that makes it checkable.

## Goal 5: MCP playthrough co-pilot

**You** play EarthBound; an LLM in chat helps with *this* save (HP, later
inventory/ailments/lookups) — not Goal 4’s “LLM is the player.”

- Transport: [MCPort](https://github.com/monofuel/MCPort) HTTP/stdio server
  (`src/tools/decompbound_mcp.nim`, `make mcp`, port 4343).
- Read-only: battery `.srm` today (`src/decompbound/party_sram.nim`); live WRAM
  / item+PSI tables later.
- Product notes: `docs/mcp-server.md`.

Does not block Goals 1–3.

## Companion apps (off the critical path)

Small desktop apps that make the project browsable and surface bugs, all built
on data we've already mapped — a live **music jukebox**, a **save-file report
card**, and a **live debug HUD** during `make play`. Full specs + definitions
of done: `docs/apps.md`. Plus an **LLM-plays-the-game** agent harness (an LLM
authors sandboxed read-only Lua to play): `docs/llm-plays.md`. And a platform
target: **EarthBound on a Raspberry Pi** game box (`docs/raspberry-pi.md`).
Plus two verification goals: raising fidelity via **test ROMs**
(`docs/accuracy.md`, the chosen alternative to multi-emulator diffing) and
**input recording & replay** — a TAS format (`docs/input-replay.md`). Sanctioned
fun; parallel-safe; none block Goals 1-3.

## Non-goals

- Bug-for-bug hardware accuracy beyond what Earthbound needs.
- Emulating other games.
- Translating existing community disassemblies wholesale (clean-room, for fun).
- Byte-matching via transcription. If a session cannot express bytes through
  the assembler, the correct move is to declare the region as data with a
  TODO, not to hardcode "temporary" literals.
