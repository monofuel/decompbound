# Project Goals

> **Current direction (phase 2):** fully understand the ROM via a real SNES
> assembler, committed ca65-convention `.asm`, and a JSON **manifest** that
> drives extract → rebuild. The gold gate is
> `extract(gold) → build() → byte-identical gold` with a **computed** header
> checksum. See [`decompilation-phase2.md`](decompilation-phase2.md) and
> [`terms.md`](terms.md).

## What we are building

1. **Understand every byte** of the user-supplied EarthBound ROM — named,
   evidenced, and explained over time.
2. **Reproduce the gold master** from source we control: assembly for code we
   understand, declarative extracts for data we identify, opaque blobs for the
   rest (still correct, just not explained).
3. **Optional modified builds** later (post-v1 linker / romhack) — not the
   current bar.

## What closed

- **Native reimplementation in Nim/C** (old Goal 3): closed. The game was never
  high-level C/Nim; a second translation layer bought a multi‑GB Nim build and
  no path to 100% that we want. Assembly *is* the decompilation target, as in
  finished SNES decomps.

## What remains true

- **Mechanical verification only.** Names must be evidence-earned. Gates are
  commands (`rom_rebuild`, tests), not self-reports.
- **Copyright hygiene.** No ROM bytes, dialogue dumps, screenshots, save-states,
  or extracted assets in git. Tools write under gitignored `extracted/`.
- **Emulator + data RE** are first-class instruments, not a detour.

## Historical goals (1 / 1.5)

Phase 1 built a 65816 assembler/disassembler in Nim and a generated scaffold
(`generated/*`) that matched gold. Goal 1.5 adopted named `snesAsm` modules.
That path is **complete as history**: `generated/*` is deleted (M2.5); adopted
content lives under `asm/*.asm`. Details: [`goal-1.md`](goal-1.md),
[`goal-1.5.md`](goal-1.5.md) (superseded banners).

## Verification today

| Gate | Command |
|------|---------|
| Tile + manifest | `nim r tests/test_manifest.nim` |
| Vanilla rebuild | `nim r src/tools/rom_rebuild.nim` / `make compare` |
| Axes report | `nim r src/tools/progress_report.nim` |
| View (optional) | `nim r src/tools/view_export.nim` |
| Suite | `make test` |

Progress is **Build × Comprehension** in bytes ([`terms.md`](terms.md)), not
“map matches gold.”
