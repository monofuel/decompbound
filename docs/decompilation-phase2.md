# Decompilation, phase 2 — the assembler pivot

**Status:** planning. Branch `snes-assembler`.
**Started:** 2026-08-02.

## Why there is a phase 2

Phase 1 (`docs/goal-1.md`, `docs/goal-1.5.md`) converted ROM regions into Nim —
generated modules first, then hand-adopted named modules — with a byte-exact
gold gate. It stalled for a reason that had nothing to do with the pipeline:
**we got stuck reverse-engineering graphics and audio**, so the work paused and
the effort went into the emulator instead.

That detour paid off. **The emulator now works** — PPU, APU, DMA/HDMA, the
scene corpus, the goldens. Graphics and audio are no longer a wall; they are an
instrument we can point at the ROM. Phase 2 is the return to decompilation with
that instrument in hand, and with a representation that can actually reach 100%.

## The goal has not changed

**Fully understand the ROM.** Every byte accounted for, named, and explained.
Everything below is about the representation that gets us there — not a
reduction in scope.

## Why the representation has to change

Phase 1's cost was measured on 2026-08-02, not assumed:

| Measurement | Result |
|---|---|
| Full build, cold, default (ORC) | **36.5 GB / 194 s** |
| Full build, cold, `--mm:refc` | 25.4 GB / 128 s |
| One generated bank (`code_bank01`, 38,873 lines) | 970 MB, `nim check` alone |
| Cost per generated line | **~25 KB of compiler memory** |
| Backend share (codegen + C compile) | **~6%** — the cost is sem/transform |
| `-d:danger`, lineDir/debuginfo/stackTrace off, exception model | **no effect** |
| `--incremental:on` warm rebuild | 0.5 GB / 1 s — but **crashes on a real edit** (`IndexDefect`), so unusable |

Two findings decide the direction.

**The macro layer was never the problem.** `snesAsm` is an `untyped` macro and
costs a flat ~36 MB above the bare compiler floor. But it lowers each DSL line
to `nodes.add instr(...)` — *the same shape* the generated modules already
emit. Adopted and generated code are identical to the compiler. The adopted
files measure cheap only because there are 2,201 lines of them.

**Therefore adoption does not fix the cost — it inherits it.** At 100%
adoption the whole ROM is ~1.3M Nim statements, i.e. the same ~25 GB. The
better the project goes, the worse the build gets.

**The floor is arithmetic.** 1.34M statements × 19 KB measured is 25 GB; even
at an implausibly good 2–4 KB per statement it is 3–5 GB. *Any* design with one
Nim statement per 65816 instruction is a multi-gigabyte build. Group A ruled out
every compiler flag; the remaining levers were all representation changes.

For reference, a purpose-built 65816 assembler doing the same job — 3 MB of
output — should be in the range of a second and well under a few hundred MB.
That is the target, and it is 2–3 orders of magnitude away from where we are.

## The pivot

**Build a proper SNES assembler and keep the game as assembly source.**

The game was written in 65816 assembly. Translating it into Nim (or C) is a
second translation layer that nobody asked for: it costs the build, and it
buys a native-reimplementation path we are choosing not to take. Assembly
source *is* the decompilation — as it is for every SNES decomp that finished.

Anything we would have wanted the host language for — macros, templates, named
constants, documented data layouts — **goes into the assembler instead.**

## What we keep

The pivot is smaller than it sounds. The front end changes; the verified core
does not.

- `src/decompbound/assembler.nim` (236 lines) — `AsmNode`, `assemble()`, label
  resolution, and the **M/X `FlagState` tracking** that makes 65816 immediate
  widths correct. This is the hard part and it already exists and is gold-tested.
- `src/decompbound/opcodes.nim` (374 lines) — the verified opcode table. Sacred.
- `src/decompbound/disasm.nim` — the reverse direction, and the source of
  generated output.
- `compare.nim` + `tests/` — the byte-exact gold gate. **Unchanged and
  non-negotiable**; every migration step stays verifiable against it.
- The emulator — now the behavioral referee for anything bytes alone can't prove.

Today the `AsmNode` stream comes from Nim AST (`snes_asm.nim`) or Nim procs
(`generated/`). In phase 2 it comes from parsed text. Same nodes, same
`assemble()`, same gate.

## What changes

- `convert_all.nim` emits **`.asm` text** instead of Nim procs.
- The 21 adopted `snes_src/` modules port to the new syntax.
- `snes_asm.nim` becomes the syntax reference, then retires.
- `generated/*.nim` (50 files, 1,335,789 lines) is replaced by assembly source.

## What this closes

Goal 3's **native reimplementation** path — swapping assembled routines for
hand-written Nim procs — is off the table. The rationale: the game was never C
or Nim, so that layer was always a translation of a translation. `docs/goal.md`
and `docs/goal-1.5.md` are written on that premise and need rewriting rather
than being left to quietly contradict this.

## What is unaffected

The emulator, all tooling, and **all data RE** — bestiary, extractors,
`sword_recipe`, text/graphics/audio decoders. None of it ever touched the
generated layer; those tools read the user's ROM at runtime and are untouched
by this change.

## Open decisions (nothing is settled)

1. **Syntax** — adopt asar/ca65/wla-dx conventions, or fit our existing
   `snes_asm` shape? Weigh: romhackers already read asar, and existing tools
   consume it. Compatibility may matter more than elegance.
2. **How M/X width is expressed** — explicit directives, inference from
   `REP`/`SEP` with asserts, or both. We have already been burned by misaligned
   widths inflating coverage; this needs to be hard to get wrong.
3. **Build model** — per-file objects plus a link step, or one fast pass over
   the tree. A 3 MB ROM is small; simplest thing that hits ~1 s may win.
4. **Data and documentation model** — typed tables, pointer tables, struct/record
   layouts, named constants carrying their evidence. *Most of the ROM is data*,
   so this is the largest share of the work and the part that most directly
   serves "understand the ROM."
5. **Macro / template system** — expansion only, or also freespace management
   and patch/overlay application? Full-rebuild hacking and patch-style hacking
   are different products.
6. **Migration order** — the gold gate makes every step verifiable; decide
   whether generated regions or adopted modules move first.

## Related

- Phase 1: [`goal-1.md`](goal-1.md), [`goal-1.5.md`](goal-1.5.md) (both need
  revision — see *What this closes*)
- Where the bytes are: [`decompilation.md`](decompilation.md)
- The emulator that unblocked this: [`accuracy.md`](accuracy.md),
  [`graphics.md`](graphics.md), [`audio.md`](audio.md)
- Delegation + verify bars: [`delegation.md`](delegation.md)
