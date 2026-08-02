# Phase 2 — implementation checklist

Ordered milestones for [`decompilation-phase2.md`](decompilation-phase2.md).
Vocabulary: [`terms.md`](terms.md). Branch: `snes-assembler`.

**v1 is done when `build()` reproduces the gold ROM byte-for-byte.** Every
milestone below ends in a gate that can be *run*, not asserted.

---

## M0 — Decide (no code)

- [ ] **Syntax**: confirm ca65 conventions (leaning) — and which parts we
      deliberately diverge on.
- [ ] **M/X width**: explicit directives, `REP`/`SEP` inference with asserts,
      or both.
- [ ] **Manifest schema v1**: fields per region — offset, length, kind, source,
      name, evidence, axis levels. This is the load-bearing design; everything
      downstream reads it.
- [ ] **Build model**: one pass over the tree vs per-file + link.

*Gate: written into the phase-2 doc as decided, not "leaning".*

## M1 — Manifest + extractor

- [ ] Manifest format implemented (parse + validate).
- [ ] Seed it from what already exists: `regions.nim`, `baserom_extract.nim`
      claims, the 21 `snes_src` routines, adopted tables.
- [ ] Extractor: gold ROM + manifest → per-region files; **everything
      unclaimed falls out as a `.bin` blob**.
- [ ] Coverage assertion: regions tile the ROM exactly — no gaps, no overlaps,
      total == 3,145,728.

*Gate: `extract` runs clean and the region map accounts for every byte.*

## M2 — Blob round-trip ⭐ the de-risking milestone

Rebuild the ROM from **blobs only** — no assembler involved yet.

- [ ] Builder: manifest + extracted files → ROM image at fixed offsets.
- [ ] Header + **computed** checksum (not the gold value copied).
- [ ] Gate: **output is byte-identical to gold.**

*Why this comes before any assembler work: it proves the manifest, the
extractor, the builder, and the gate all work, while every region is still
`copy`/`unknown`. From here every later milestone is "move regions up an axis
without breaking a gate that already passes."*

## M3 — Assembler front end

- [ ] Text parser → `AsmNode` (reuse `assembler.nim`'s `assemble()`,
      `opcodes.nim`, and the existing `FlagState` tracking).
- [ ] Width directives wired to `flagHint`.
- [ ] Labels, data directives, constants, comments.
- [ ] **Differential test** against the reference assembler on the same source.
- [ ] Gate: one hand-written region assembles byte-exact.

## M4 — Code regions become `.asm`

- [ ] `convert_all` emits `.asm` text instead of Nim procs.
- [ ] Migrate generated banks to `.asm`, region by region — each flips from
      `copy` to `reproduce` with the gold gate green after every step.
- [ ] Gate: full ROM still byte-exact.
- [ ] **Performance gate**: full build ≤ ~2 s and ≤ a few hundred MB. *(This is
      the whole reason for phase 2 — if it isn't met, stop and rethink before
      migrating further.)*

## M5 — Retire the Nim representation

- [ ] Port the 21 adopted `snes_src` modules to `.asm` (keeping names,
      comments, and evidence — that's the `explained` content, don't lose it).
- [ ] Delete `generated/*.nim` (1,335,789 lines) and `snes_asm.nim`.
- [ ] Gate: gold gate green; `make test` green; build stays cheap.

## M6 — Reporting on the real axes

- [ ] `compare`/`report` emits Build × Comprehension per `terms.md`, in bytes,
      excluding coincidental matches.
- [ ] Gate: new numbers reconcile with the current tiers (nothing silently
      promoted by the rewrite).

## M7 — View path (parallel, not blocking)

Humans-see-it work. Never on the build path in v1.

- [ ] Graphics → PNG.
- [ ] Audio → WAV (one-way; BRR stays the build source).
- [ ] Script → text.
- [ ] Data tables → CSV/JSON.

## M8 — Docs reconciliation

- [ ] Rewrite `goal.md` / `goal-1.5.md` — they are written on the
      native-reimplementation premise that phase 2 closes.
- [ ] Fold the adoption pipeline's evidence rules into the new flow.

---

## Post-v1 (explicitly out of scope until the gate is green)

- Pointers computed from symbols → the whole-ROM **linker**, freespace
  allocation, relocation. Unlocks `modify`.
- Codecs proven bit-identical, one asset class at a time — each graduates its
  class from view-only to editable. `gfx_lz` is already proven, so graphics is
  the natural first.
- Macro / template system for hacks.
- Patch-based hack distribution (assets are copyrighted, so hacks ship as
  diffs against the user's own extraction — which makes deterministic builds a
  hard requirement).

---

## Standing rules

- Every milestone gate is a **command**, never a self-report
  ([`delegation.md`](delegation.md)).
- The gold gate is sacred and stays green between milestones — migrate a region
  at a time, not a bank at a time.
- Names carry evidence or they don't land.
- Nothing game-derived gets committed at any step.
