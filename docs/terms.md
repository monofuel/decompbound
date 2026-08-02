# Terms — the classification matrix

**Status:** canonical vocabulary. Other docs link here instead of redefining.
**Updated:** 2026-08-02.

This file defines how we classify every byte of the ROM and the words we use
for it. If a term is used loosely somewhere else, this file wins.

---

## The three axes

Every **region** carries a position on three independent axes. They are
independent on purpose: the most common confusion in this project is treating
"matches gold" as "understood," and separate axes make that impossible to say
by accident.

### Axis 1 — Build: how do these bytes get into the ROM?

| Level | Name | Meaning |
|---|---|---|
| **B0** | `copy` | Copied verbatim from the gold master at build time. Correct, but we couldn't produce it ourselves. |
| **B1** | `reproduce` | The build **regenerates** it from source (assembly, a manifest description, or a proven codec) and the result is byte-identical. |
| **B2** | `modify` | It can be *changed* and the ROM still builds correctly — requires computed pointers and relocation. **Post-v1.** |

### Axis 2 — Comprehension: do we know what it is?

| Level | Name | Meaning |
|---|---|---|
| **C0** | `unknown` | No claim. We know where it is and nothing else. |
| **C1** | `identified` | Extent and **kind** claimed (e.g. "4bpp tileset, 128 tiles", "record table, stride `0x5E`"). Shape known, meaning not. |
| **C2** | `explained` | **Named, documented, evidence attached** — what it does, why we believe that, and where the evidence lives. |

### Axis 3 — Rights: may we commit our representation?

| Class | Meaning |
|---|---|
| `ours` | Our own new expression — annotated disassembly, format descriptions, tools, the manifest. **Committable.** |
| `theirs` | The copyrighted work itself — graphics, audio, script text, data content. **Never committed**; extracted from the user's ROM at build time. |

Two clarifications that get muddled:

- The original code **is** copyrighted. Our annotated disassembly is committable
  because it is *transformative new expression* — our labels, comments, and
  cross-references are the added authorship (the SM64/OoT basis, see
  `AGENTS.md` → Copyright hygiene). "The asm isn't copyrighted" is the wrong
  reason for the right conclusion.
- Decoding an asset does **not** launder it. A sprite exported to PNG is still
  their sprite. The *description* of a format is always `ours`; the *content* is
  always `theirs`.

---

## The matrix

Build × Comprehension is the grid that matters. Rights is orthogonal metadata.

|  | **C0 unknown** | **C1 identified** | **C2 explained** |
|---|---|---|---|
| **B0 copy** | unclaimed bytes | extract claim — e.g. `apu_package` | fully documented but not re-encodable — **audio in v1** |
| **B1 reproduce** | **scaffold** — assembles byte-exact, nobody has read it | table emitted from its manifest description | **the target** — adopted, named routines |
| **B2 modify** | *(meaningless)* | editable data | editable, documented — **the romhack end state** |

**The goal is to move every byte toward the bottom-right.** v1 stops at the
`B1 reproduce` row; `B2 modify` is post-v1 work.

This grid is why two true statements sound contradictory: **89.81% of the ROM
is byte-exact** and **0.064% is understood**. The first is the B1 row, the
second is the C2 column. Both are correct because they measure different axes.

---

## Where we are (from `report.md`, 2026-08-02)

ROM total: **3,145,728 bytes**.

| Current tier | Axes | Bytes | Share |
|---|---|---|---|
| PRIMARY — truly understood | B1 / C2 | 2,026 | **0.064%** |
| SECONDARY — extract claims | B0 / C1 | 307,283 | 9.77% |
| MAP ONLY — anonymous scaffold | B1 / C0 | 2,825,303 | 89.81% |
| Header + vectors | — | 80 | — |

Extract claims by kind: `table` 108,704 · `gfx_lz` 99,164 · `apu_package`
49,846 · `script_stream` 21,352 · `zero_pad` 15,122 · `action_script` 13,095.

---

## Counting rules

1. **Count bytes, not regions.** A region count flatters small claims.
2. **Coincidental matches are never progress.** A byte that happens to match
   (zero-fill, or a lucky collision) is not a claim. `report.md` already tracks
   these separately and labels the inflated figure "do not track" — keep that.
3. **Levels are derived, never self-reported.**
   - `B1 reproduce` is proven *by the build*: the region came from source and
     the ROM still matches gold.
   - `C1`/`C2` are derived from the manifest — does the entry have a kind, a
     name, and attached evidence?
   - Rights follow from the kind.
   Nobody promotes a region by asserting they understand it.
4. **A region sits at the lowest level it can prove.**

---

## Glossary

- **Gold master / gold ROM** — the user's own legally dumped ROM. The single
  source of truth for every byte. Never committed.
- **Byte-exact** — output is bit-identical to the corresponding gold bytes.
- **Region** — a contiguous span of the ROM with one manifest entry.
- **Manifest** — the declarative description of every region. Drives
  extraction *and* rebuild as inverse readings of the same file; it is also the
  linker config. See [`decompilation-phase2.md`](decompilation-phase2.md).
- **Blob** — a region extracted verbatim with no claim beyond its extent
  (`B0`/`C0`). Legitimate and expected — a blob is *correct*, just not
  *explained*.
- **Scaffold** — generated code spans that assemble byte-exact but that nobody
  has read (`B1`/`C0`). Fills the map; is not the decomp needle.
- **Extract claim** — a region whose *format and layout* we claim, but whose
  *content* is read from gold at build time (`B0`/`C1`).
- **Build path / view path** — the build path must reproduce bytes exactly; the
  view path renders regions into modern files (PNG, WAV, text) for humans and
  may be lossy or one-way. Extraction for understanding does not have to feed
  the build.
- **Round-trip** — `extract(gold)` then `build()` reproduces gold exactly.
- **The gold gate** — the round-trip check. The referee for everything; never
  subcontracted, never merged on a self-report.
- **Vanilla build** — must be byte-identical to gold. **Modified build** —
  opt-in changes; byte-exactness no longer applies, so the emulator becomes the
  referee.
- **Evidence-earned name** — a name backed by trace data, disassembly at named
  offsets, or a byte-level argument. A wrong name lies to everyone downstream,
  so an unevidenced name is worse than no name.
- **Coincidental match** — bytes that match gold without being claimed. Not
  progress.

---

## Related

- [`decompilation-phase2.md`](decompilation-phase2.md) — the plan these terms serve
- [`decompilation.md`](decompilation.md) — where the bytes actually are
- `AGENTS.md` → Copyright hygiene · [`copyright-notes.md`](copyright-notes.md)
