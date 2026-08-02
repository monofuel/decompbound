# Decompilation, phase 2 — the assembler pivot

**Status:** M2.5–M8 complete on `snes-assembler` (annotated `asm/`, axes report,
view path, docs). **Started:** 2026-08-02.

> **Historical:** Before M2.5, compiling `generated/*` bank modules peaked at
> **~36.5 GB / 194 s**. Those modules are **gone**. Vanilla rebuild is
> `rom_extract` + `rom_rebuild` (manifest + `extracted/`). Prefer targeted
> `nim r tests/test_*.nim` still; `make test-banks` is a no-op retired target.

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

---

# The end-to-end flow

The assembler is **one component**, not the project. The product is a
round-trip: take the user's gold ROM apart into editable modern files, and put
it back together byte-for-byte — with the option of putting it back together
*differently*.

```
gold.smc ──extract──▶  extracted/   (gitignored, per-user: .bin blobs, view
   │                                  exports, anything derived from the ROM)
   │                   asm/         (committed: our own new expression)
   │                   data/        (committed: formats, offsets, evidence)
   │                   manifest.json  (committed: layout — drives extract + build)
   │                        │
   │                     build
   │                        ▼
   └──────compare──────  out.smc        must be BYTE-IDENTICAL
                            │
                            └─ + opt-in changes ──▶ romhack build
```

**Extract root is `extracted/`** (not `bin/` — that tree is already overloaded).
The directory is git-ignored; only the user's own gold ROM populates it.

## The round-trip is the gate

`extract(gold)` then `build()` must reproduce `gold` **exactly**. That single
invariant replaces "does our disassembly match" with "does our understanding of
the entire ROM reproduce it" — code, graphics, audio, script, tables, and the
parts we still don't understand.

This generalizes `compare.nim` from a code metric to a whole-ROM one, and it
subsumes the current gold gate rather than replacing it.

## Scope: v1 is "reproduce the gold master"

**v1 ships when `build()` reproduces the gold ROM byte-for-byte. Nothing more.**
Editability, relocation, and hacking are incremental work on top of a working
round-trip — not prerequisites for it.

This collapses most of the hard parts:

- **No linker, no freespace allocation, no relocation.** Pointers keep their
  original values. We are rebuilding a fixed layout, not laying one out.
- **No bit-identical re-encoder needed for every codec.** Anything we can't
  re-encode exactly rebuilds from its **original bytes**.

### Build path vs view path

The key move that makes this work: separate the two directions.

| | Build path | View path |
|---|---|---|
| Purpose | reproduce gold, byte-exact | let humans see/hear/read it |
| Source | whatever reproduces the bytes (original blob, or a proven codec) | modern lossless files — PNG, WAV, text, JSON |
| Constraint | **must** round-trip | may be lossy or one-way |

Extraction to modern formats is for *understanding*. It does not have to feed
the build. That means we can export BRR samples to WAV to listen to them
without WAV ever being on the rebuild path.

As each codec is proven bit-identical, its class graduates from view-only to
editable and the two paths converge. `gfx_lz` is already proven; the rest are
future work, unlocked one at a time.

### Audio is one-way for now — accepted

EarthBound's audio is generated programmatically: BRR samples plus sequence
data driving the SPC700, not files in any modern sense. BRR is lossy 4-bit
ADPCM, so decode-to-WAV then re-encode cannot reproduce the original bytes.

**Decision: audio is view-only in v1.** Rebuild uses the original BRR and
sequence bytes; WAV export exists purely for listening. Editing music is
deferred, and when it lands it is a romhack-only path the gold gate can't
cover.

## How we classify what's understood

Every region carries a position on three independent axes — **Build**
(`copy`/`reproduce`/`modify`), **Comprehension**
(`unknown`/`identified`/`explained`), and **Rights** (`ours`/`theirs`).
Definitions, the matrix, the counting rules, and the glossary live in
**[`terms.md`](terms.md)** — that file is canonical; this one doesn't
redefine them.

The short version: v1 drives the ROM to the `reproduce` row, and the
project's headline metric is the `explained` column. Keeping them separate is
what makes "89.81% byte-exact" and "0.064% understood" both true statements
about the same ROM instead of a contradiction.

## Blobs are allowed, and tracked

Anything not yet understood stays an opaque `.bin` extracted verbatim. The ROM
still rebuilds byte-exact — an unclaimed blob is *correct*, just not
*explained*. Progress is the shrinking share of the ROM that is blob rather
than meaningful source. This is exactly how sm64 and OoT progressed, and it
means the round-trip works from day one instead of after everything is RE'd.

## Format per asset class (proposed)

Lossless and editable in ordinary tools is the goal; byte-exact round-trip is
the constraint.

| Class | View-path format | On the build path? |
|---|---|---|
| Tiles / sprites | indexed PNG (indices *are* the pixel values) + palette | exact |
| Compressed graphics | PNG + re-compress via `gfx_lz` | exact **only if our compressor is bit-identical** — already proven for `gfx_lz` |
| Tilemaps / arrangements | TSV or JSON (or Tiled) | exact |
| Palettes | JSON/`.pal`, or carried in the PNG | exact |
| Maps, doors, warps | JSON | exact |
| Data tables (enemy/item/PSI) | CSV/JSON | exact |
| Script / dialogue | UTF-8 text with explicit control codes | exact — needs a bit-identical encoder |
| Music sequences | text (MML-like) | exact once we write the encoder |
| **BRR samples + sequences** | WAV / text, for listening only | **no — original bytes rebuild** |
| Code | `.asm` | exact |
| Not yet understood | `.bin` | exact by construction |

## The build process

### What ca65 would (and wouldn't) do for us

For reference, since we're borrowing its conventions: `ca65` assembles `.s` →
`.o`, `ld65` links per a config declaring memory areas and segments, and it can
emit a raw binary — so it *does* produce the final ROM. But it only understands
**bytes**. It has no notion of a sprite. Assets get in via `.incbin` of files
already in the game's native format, so a real ca65 project needs converters
before the assembler and a checksum fixup after the linker:

```
sprite.png ─[convert]→ sprite.4bpp ─.incbin→ ca65 → ld65 → rom ─[checksum]→ final
```

That's also how sm64 works: modern files in the repo, a build step converts
them to console formats, then they're linked.

### v1 needs none of that

The build-path/view-path split removes the whole conversion stage from v1:

```
manifest ─┬─ code region     ──▶ assemble .asm
          ├─ data region     ──▶ verbatim .bin (native format, extracted as-is)
          └─ unclaimed       ──▶ .bin blob
                     │
              place at fixed offsets
                     ▼
              header + computed checksum
                     ▼
                  out.smc ──compare──▶ gold      byte-identical
```

**No converters on the build path.** PNG/WAV/text export is a separate viewer
tool humans run; the rebuild never touches it. Bitmap→4bpp conversion is real
work, but it is not v1 work — it is the **graduation mechanism**: when a
converter is proven round-trip exact, that asset class moves from "incbin the
original bytes" to "convert the source file," one class at a time, with the gold
gate proving each move.

Design note for when converters do arrive: keep a dumb `.incbin` path always
available alongside any higher-level directive, so we can drop to raw bytes
whenever a converter isn't trusted yet. The converters stay standalone Nim
modules (`gfx_lz`, `text_decode`, the decoders already are), callable from
either the build or a viewer.

### The one unavoidable post-step

The SNES internal header checksum is computed over the finished image, so it
can't come from the assembler. We have `header.nim` already. **Compute it
rather than emitting the gold value** — if we compute it and the ROM still
matches, that's proof we understand the header rather than a hardcoded
work-around.

## The manifest is the linker config

*(This answers open decision #8, and it is probably the load-bearing choice of
phase 2 — more than the syntax.)*

ca65 keeps three separate artifacts: the linker config, the source, and
external converters. Writing our own assembler means we don't have to.

**One declarative description drives both directions.** A manifest entry like
"the region at `0x159589` is a table of 231 records, stride `0x5E`, fields …"
tells the extractor how to take it apart *and* tells the build where to put it
back. Extraction and rebuild become inverse readings of the same file.

**Format: JSON** (`manifest.json`, committed). Schema and granularity (which
fields an entry carries, how fine the regions are) are still open; the
serialization format is not.

That gives us:

- **A single source of truth** for layout — no drift between how we read the
  ROM and how we write it.
- **The place pointer-table descriptions live** (see below) even while v1 emits
  original literal values.
- **The progress ledger** — what's described versus what's still an opaque blob
  is exactly the "how much do we understand" metric, readable straight off the
  manifest.
- **The future linker's input**, unchanged in form, when relocation lands.

Its schema — fields, granularity, how evidence is attached to an entry — is the
next thing to work out.

## Pointers — deferred, but don't paint over them

In v1 pointers keep their original values, so there is nothing to solve: a
fixed layout reproduces a fixed layout.

The problem arrives the moment an asset changes size — every pointer to it,
every pointer table, and every bank-layout assumption moves with it. Solving
that means computing pointers **from symbols, for data as well as code**, which
turns the assembler into a whole-ROM **linker** with freespace allocation. That
is the single biggest piece of post-v1 work, and it is what unlocks real
romhacking.

Two things to get right in v1 so that future work isn't blocked:

- **Where we understand a pointer table, describe it as a table** (base, stride,
  count, target) even though v1 emits the original bytes. The description is the
  seed of the symbol model; discovering it later from a wall of literals is far
  harder.
- **Keep the layout description declarative** rather than baking offsets into
  procedural code, so a future linker can consume the same manifest.

The eventual payoff is a strong check: once pointers are computed, a vanilla
build's computed values must equal the originals — so byte-exactness would
prove the pointer *model*, not just the bytes.

## Copyright shapes distribution

Extracted assets live under **`extracted/`**, are **per-user and git-ignored** —
they're the copyrighted work. Consequences:

- A romhack **cannot ship assets**. It ships as a **patch**: source diffs plus
  asset diffs (or a BPS against the built ROM) that the user applies to *their
  own* extraction.
- That makes **deterministic builds mandatory**. Same inputs must give the same
  bytes on every machine, or patches don't apply.
- The repo keeps only extractors, codecs, formats, evidence, and `.asm` — the
  existing `AGENTS.md` rule, now load-bearing for the whole product.

## Vanilla vs modified builds

Two build modes, one pipeline:

- **`vanilla`** — must be byte-identical to gold. The primary gate; CI-able for
  anyone with their own ROM.
- **`with changes`** — opt-in bug fixes or hacks, layered as explicit patches.
  Byte-exactness no longer applies, so the referee becomes the **emulator**:
  it boots, it plays, the tests pass, the scene corpus renders.

Bug fixes are opt-in rather than default, so "reproduce the artifact exactly"
and "make a better version" never fight.

## Decided

1. **Syntax: ca65 conventions** (monofuel, 2026-08-02). We write our own
   assembler in Nim; this is a choice of *conventions to implement*, not a tool
   to depend on — and we diverge where ca65's shape doesn't fit.
   - `.a8`/`.a16`/`.i8`/`.i16` map almost one-to-one onto the
     `FlagState`/`flagHint` model we already have working and gold-tested.
     `.struct`/`.enum`/scopes/segments give real vocabulary for data layouts.
     The assemble-then-link-with-a-memory-config model is the architecture the
     post-v1 linker needs, so v1 isn't thrown away to get there.
   - Real ca65 is the **differential-testing oracle** — same source, diff
     bytes against ours.
   - Asar remains interesting for patch-first hack distribution later; it is
     not the v1 syntax.
   - *Not a factor:* an unlicensed ca65 EarthBound decomp exists on GitHub. We
     have not cloned or read it and will not. Syntax choice is unrelated to
     that; evidence-earned names and the gold gate remain the derivation trail.
2. **Manifest serialization: JSON** — committed as `manifest.json` (or a
   small set of JSON files if we split later).
3. **Extract root: `extracted/`** — git-ignored, per-user, populated from the
   gold ROM. Not under `bin/` (already overloaded).
4. **The manifest is the linker config** — one declarative description drives
   extract and build.
5. **v1 is fixed-layout**, original pointer values. Linker deferred.
6. **M/X width: both** — explicit `.a8`/`.a16`/`.i8`/`.i16` directives (map to
   `flagHint`) **and** `REP`/`SEP` tracking inside `assemble()`. Explicit
   directives win at the point they appear; inference fills the gaps. Hard to
   get wrong after past width-coverage burns.
7. **Build model: one pass** — place regions at fixed offsets from the
   manifest in a single pass. No per-file objects or link step in v1 (3 MB ROM;
   fixed layout). A real linker is post-v1.
8. **Manifest schema v1** — JSON object:
   - top-level: `version` (int, currently `1`), `romSize` (int, must be
     `3145728`), `regions` (array)
   - each region: `name` (string), `offset` (int), `length` (int), `kind`
     (`blob`|`code`|`data`|`header`|`vectors`), `source` (path relative to
     `extracted/`), `build` (`copy`|`reproduce`|`modify`), `comprehension`
     (`unknown`|`identified`|`explained`), optional `evidence` (string)
   - coverage: regions must tile `[0, romSize)` with no gaps and no overlaps
   - v1 seeds may use a single full-ROM `blob`/`copy`/`unknown` entry; finer
     cuts land as comprehension grows without breaking the gate

## Open decisions

1. **Data and documentation model** — typed tables, pointer tables, struct/record
   layouts, named constants carrying their evidence. *Most of the ROM is data*,
   so this is the largest share of the work and the part that most directly
   serves "understand the ROM."
2. **Macro / template system** — expansion only, or also freespace management
   and patch/overlay application? Full-rebuild hacking and patch-style hacking
   are different products.
3. **Migration order** — the gold gate makes every step verifiable; decide
   whether generated regions or adopted modules move first.
4. **Extraction granularity and naming.** Asset filenames must be stable across
   re-extraction so edits survive, and named from evidence (same rule as code
   adoption — a wrong name lies). Root dir is `extracted/`; path layout under
   it is still open beyond the schema's `source` field (v1 uses `blobs/…`).
5. **Which codecs to prove bit-identical, and in what order** — post-v1, each
   one graduates its asset class from view-only to editable. `gfx_lz` is
   already proven; graphics is therefore the natural first class to unlock.

## Implementation checklist

**v1 is done when `build()` reproduces the gold ROM byte-for-byte.** Every
milestone ends in a gate that can be *run*, not asserted.

### M0 — Decide (no code)

- [x] **Syntax**: ca65 conventions (diverge only where we must).
- [x] **Manifest format**: JSON (`manifest.json`).
- [x] **Extract root**: `extracted/` (git-ignored; not `bin/`).
- [x] **M/X width**: both — explicit `.a8`/`.a16`/`.i8`/`.i16` + `REP`/`SEP` tracking.
- [x] **Manifest schema v1**: see Decided #8 (fields + tile invariant).
- [x] **Build model**: one pass, fixed offsets (no linker in v1).

*Gate: remaining items written into this doc as decided, not "leaning".*
### M1 — Manifest + extractor

- [x] Manifest JSON parse + validate (`src/decompbound/manifest.nim`).
- [x] Seed: committed `manifest.json` tiles the full ROM (`reproduce` adopted
      `asm/*` + residual `copy` blobs).
- [x] Extractor: gold + manifest → per-region files under `extracted/`
      (`src/tools/rom_extract.nim`).
- [x] Coverage assertion: regions tile the ROM exactly — no gaps, no overlaps,
      total == 3,145,728 (`tests/test_manifest.nim`).

*Gate: `extract` runs clean and the map accounts for every byte.*

### M2 — Blob round-trip ⭐ the de-risking milestone

Rebuild the ROM from **blobs only** — no assembler yet.

- [x] Builder: manifest + files under `extracted/` → ROM image at fixed offsets
      (`src/decompbound/rom_pipeline.nim`, `src/tools/rom_rebuild.nim`).
- [x] Header + **computed** checksum (`computeSnesChecksum` /
      `writeSnesChecksum` — not pasting the gold checksum as the rebuild).
- [x] Gate: **output is byte-identical to gold.**

*Why before the assembler: it proves the manifest, extractor, builder and gate
together while every region is still `copy`/`unknown`. After this, every
milestone is "move regions up an axis without breaking a gate that already
passes."*

### M2.5 — Gut the Nim representation ⭐ lifts the build restriction

The moment M2 is green, `generated/*.nim` is redundant: it is
`reproduce`/`unknown` scaffold, machine-produced by `convert_all`, regenerable
on demand, and **read by nobody**. The blobs make the same bytes. Deleting it
loses no knowledge.

- [x] Delete `src/decompbound/generated/*.nim` (bank modules + registry).
- [x] Delete the phase-1 adoption tooling that only services it:
      `verify_seed_regions`, `verify_sandwich_seeds`, the `patch_*_seeds` tools,
      and the `probe_*` files that import banks.
- [x] Retire bank-monster tests and point `make compare` / `make build` at the
      blob extract→rebuild gate.
- [x] **Kept through M2.5 then ported at M5:** adopted content is now `asm/*.asm`;
      still keep `assembler.nim`, `opcodes.nim`, `disasm.nim`, lightweight
      `code_spans.nim` (offsets only). `snes_src/` / `snes_asm.nim` deleted at M5.

*Gate: blob round-trip still byte-exact; a full build is now cheap; the ⚠
warning at the top of this doc is removed.*

### M3 — Assembler front end

- [x] Text parser → `AsmNode` (`src/decompbound/asm_parse.nim`; reuses
      `assemble()`, `opcodes.nim`, `FlagState`).
- [x] Width directives wired to `flagHint` (`.a8`/`.a16`/`.i8`/`.i16`).
- [x] Labels and `;` / `//` comments; `REP`/`SEP` width tracking in the parser.
- [x] Data directives (`.byte`/`.word` via `ankRaw`) used by table `.asm`.
- [ ] Named equates as first-class assembler symbols (values still inlined with
      name comments in adopted `.asm`) — post-v1 polish.
- [ ] **Differential test** against real ca65 when installed (in-repo fixtures
      already byte-exact in `tests/test_asm_parse.nim`).

*Gate: one hand-written region assembles byte-exact.* — **met** via fixtures.

### M4 — Code regions become `.asm`

- [x] `convert_all` emits ca65 `.asm` under `asm/scaffold/` (+ refreshes `code_spans.nim`).
- [x] Adopted explained regions live under `asm/*.asm` as `reproduce` in `manifest.json`.
- [x] Residual ROM stays `copy` blobs (v1 allows this; not every residual is `.asm`).
- [x] Gate: full ROM still byte-exact (`rom_rebuild`).
- [x] **Performance gate**: rebuild is blob place + small `.asm` assembles (no multi‑GB banks).

### M5 — Port the adopted modules

- [x] Port adopted routines/tables to `asm/*.asm` (names + evidence headers).
- [x] Delete `snes_src/` and `snes_asm.nim`; `adopted.nim` assembles from `.asm`.

*Gate: gold gate green; `make test` green.*

### M6 — Reporting on the real axes

- [x] `src/tools/progress_report.nim` + `progress_report.nim` emit Build ×
      Comprehension per [`terms.md`](terms.md) from `manifest.json` (claimed
      bytes only — no coincidental matches).

*Gate: new numbers reconcile with the current tiers — nothing silently promoted
by the rewrite.*

### M7 — View path (parallel, never blocking)

- [x] `src/tools/view_export.nim` → `extracted/view/`: graphics PNG, audio WAV
      (one-way), script text, tables CSV/JSON. Does not feed vanilla rebuild.

### M8 — Docs reconciliation

- [x] Rewrite `goal.md` / `goal-1.5.md` off the native-reimplementation premise.
- [x] Evidence rules pointed at phase-2 manifest + `.asm` flow.

### Post-v1 (out of scope until the gate is green)

- Pointers from symbols → whole-ROM **linker**, freespace, relocation. Unlocks
  `modify`.
- Codecs proven bit-identical, one asset class at a time. `gfx_lz` is already
  proven, so graphics is the natural first.
- Macro / template system for hacks.
- Patch-based hack distribution (assets are copyrighted, so hacks ship as diffs
  against the user's own extraction — which makes deterministic builds a hard
  requirement).

### Standing rules

- Every gate is a **command**, never a self-report ([`delegation.md`](delegation.md)).
- The gold gate stays green between milestones — migrate a region at a time.
- Names carry evidence or they don't land.
- Nothing game-derived gets committed at any step.

## How to run the phase-2 gates

From the repo root (gold at `bin/Earthbound (U) [!].smc` or `DECOMPBOUND_ROM`).

| Gate | Command |
|------|---------|
| Manifest tile | `nim r tests/test_manifest.nim` |
| Extract | `nim r src/tools/rom_extract.nim` → `extracted/` |
| Rebuild + gold cmp | `nim r src/tools/rom_rebuild.nim` (or `make compare`) — `BYTE-IDENTICAL` |
| Adopted asm | `nim r tests/test_rng.nim` / `tests/test_action_script_fetch.nim` |
| Assembler front end | `nim r tests/test_asm_parse.nim` |
| Axes report | `nim r src/tools/progress_report.nim` → `report.md` |
| View path | `nim r src/tools/view_export.nim` → `extracted/view/` |
| Full suite | `make test` |

Committed: `manifest.json`, `asm/*.asm`. Gitignored: `extracted/` (blobs + view).

## Related

- Phase 1: [`goal-1.md`](goal-1.md), [`goal-1.5.md`](goal-1.5.md) (both need
  revision — see *What this closes*)
- Where the bytes are: [`decompilation.md`](decompilation.md)
- The emulator that unblocked this: [`accuracy.md`](accuracy.md),
  [`graphics.md`](graphics.md), [`audio.md`](audio.md)
- Delegation + verify bars: [`delegation.md`](delegation.md)
