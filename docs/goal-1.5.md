# Goal 1.5: The Adoption Campaign

Goal 1 answered "can we produce byte-matching output from source?" — yes,
via `src/decompbound/generated/`: 266 machine-generated regions, verified
against gold. But generated code is a *transcription*, not understanding:
`generateCode00A11C` tells you nothing, and `LDA #$30 / STA $307FF0` reads
as magic until someone decodes it.

Goal 1.5 treats `generated/` as **scaffolding to be replaced**. Region by
region, hand-curated modules with real names, documentation, and symbolic
constants take over — while the byte-exactness invariant holds the whole
time. The scaffold holds the building up until the real walls exist.

## The design lens: what would a romhacker want to read?

The end state is not "a copy of the ROM." It is **Earthbound as a
buildable Nim project**: readable, documented source that assembles to the
exact gold ROM by default — and where changing one instruction in an
understood region produces a valid, buildable, modified Earthbound. Purity
mode proves fidelity; hack mode is the payoff. (The README's original
"compiler flags for bug fixes" idea lands here.)

What that reader needs:

- **Real routine names**: `sramMirrorPiracyCheck`, not `generateCode00A11C`.
- **Doc comments** stating what a routine does, its inputs/outputs
  (registers), and what it clobbers.
- **A named memory map**: WRAM variables (`vblankFlag = $002B`), MMIO
  registers, SRAM layout — one shared module, no magic addresses.
- **Symbolic constants** for flag masks and test patterns, with comments
  where the value itself is the point.

## What adopted code looks like

A curated module per routine/cluster, using a `snesAsm` macro (shady-style:
Nim AST in, our existing `AsmNode` list out) so the source reads like
labeled assembly:

```nim
proc sramMirrorPiracyCheck*(): seq[uint8] =
  ## Copier detection: writes distinct bytes to two SRAM mirror
  ## addresses. On a real 8KB cart they collide; oversized copier
  ## SRAM keeps them separate and boots the crime-lecture screen.
  snesAsm origin = SramCheckAddr:
    sep M8
    lda 0x30
    sta long SramProbeA        # $30:7FF0
    inc a
    sta long SramProbeB        # $31:7FF0 - same physical byte on cart
    cmp long SramProbeA
    ...
```

The macro is sugar only: it lowers to the same `AsmNode`/`assemble()`
machinery Goal 1 verified. **Zero new verification surface.**

## Migration mechanics (shipped)

The pipeline is built and proven end-to-end:

1. A curated module registers its region in `adopted.nim` →
   `allAdoptedRegions()` as `(name, offset, data: yourProc())`.
2. `tools/convert_all.nim` **carves that byte-range out** of the traced
   code (`adoptedRanges()`), so a curated routine can sit **mid-region**,
   not only on a traced-region boundary. The enclosing block simply splits
   around the adopted span — no generated file to hand-delete.
3. The per-region gold test (`tests/test_regions.nim`) is the adoption
   gate: rename and document all you want — every region must still be
   byte-exact against gold, and no two regions may overlap.

Adoption is therefore un-fakeable. Each adoption is a small,
self-contained, independently verifiable unit of work — ideal ticket shape
for agent sessions.

Mid-region carving was the missing piece: before it, only routines that
happened to start on a boundary (`sramMirrorPiracyCheck` at `$C0A11C`)
could adopt. The RNG advance (`$C08E9A`) is buried inside the 811-byte
`$C08C6D` block; carving splits it 557 + [56 adopted] + 198.

## The metric (live in `make compare`)

**Adopted bytes vs. scaffold bytes** — the "% understood" number that fixes
what the raw byte-match percentage could never express. It only moves
through actual comprehension, because adopted output must still be
byte-identical to gold. `make compare` now prints it:

```
Understood (Goal 1.5 adopted): 110 bytes = 0.06% of decompiled — readable, named, documented Nim
```

Baseline 110 bytes = `sramMirrorPiracyCheck` (54) + `earthboundRandom` (56).
This is the number the Adoption Campaign drives up.

## Where understanding comes from

Adoption *spends* understanding; the other campaigns *mint* it:

- The emulator's dynamic tracing shows what reads/writes an address
  (that's how `$002B` became "the vblank flag").
- The audio campaign named the APU upload routine ($AB06), the play-music
  entry ($C0856B), and the driver's warm/cold boot check as byproducts.
- The graphics campaign will name the decompressor; the scripting campaign
  will name the text VM behind the `frontier.md` jump tables.

So the recommended order stands: chase audio/graphics/scripting for joy
and knowledge; adopt regions opportunistically as understanding falls out.

**Adopted so far:**

- `sramMirrorPiracyCheck` (`$C0A11C`, 54 bytes) — the copier-detection SRAM
  mirror trick; first adoption, boundary-aligned.
- `earthboundRandom` (`$C08E9A`, 56 bytes) — the PRNG advance; first
  **mid-region** adoption, and it already has a native Nim mirror
  (`rng.nim` reimpl matched the emulator 10/10), the "dual implementation"
  below in embryo.

Next candidates (understanding already minted, awaiting the lift): the APU
upload routine (`$C0AB06`) and the audio helpers documented in
`docs/audio.md`; the RNG cold-init seed (`$C08121`) once adopted as part of
its whole enclosing boot routine (do not carve a bare fragment out of a
routine you have not named).

## Someday: dual implementations

For key routines, a plain Nim mirror of the algorithm next to the asm —
cross-verified by *executing both* (the CPU core runs the asm, native Nim
runs the mirror, results compared). That is goal.md's verified-dual-
implementation idea; the vector-proven `cpu.nim` makes it practical.

## Non-goals

- Decompiling to C or pretending hand-written asm has higher-level source.
- Bulk-renaming without evidence. A name must be earned by trace data,
  behavioral observation, or byte-level understanding — a wrong name is
  worse than `generateCode00A11C`, because it lies.
- Breaking byte-exactness. Hack mode is a deliberate build flavor, never
  an accident; purity is the default and CI enforces it.
