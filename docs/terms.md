# Terms

Canonical definitions for decompbound. Other docs link here rather than
redefine. No project state lives in this file.

Every **region** has a position on three independent axes.

## Axis 1 — Build

How the region's bytes get into a built ROM.

| Level | Name | Definition |
|---|---|---|
| **B0** | `copy` | Copied verbatim from the gold master at build time. |
| **B1** | `reproduce` | Regenerated from source (assembly, a manifest description, or a proven codec), byte-identical to gold. |
| **B2** | `modify` | Can be changed and still build correctly. Requires computed pointers and relocation. |

Determined by the build, not by assertion: a region is `reproduce` only if it
came from source and the ROM still matched gold.

## Axis 2 — Comprehension

How well the region is understood.

| Level | Name | Definition |
|---|---|---|
| **C0** | `unknown` | No claim beyond the region's extent. |
| **C1** | `identified` | Kind and shape claimed — e.g. "4bpp tileset, 128 tiles", "record table, stride `0x5E`". Meaning not claimed. |
| **C2** | `explained` | Named and documented, with evidence attached. |

Determined by the manifest entry: whether it carries a kind, a name, and
evidence.

## Axis 3 — Rights

Whether our representation of the region may be committed.

| Class | Definition |
|---|---|
| `ours` | Our own new expression — annotated disassembly, format descriptions, tools, the manifest. Committable. |
| `theirs` | The copyrighted work itself — graphics, audio, script text, data content. Never committed; extracted from the user's ROM at build time. |

A format's *description* is always `ours`; its *content* is always `theirs`.
Annotated disassembly is `ours` because the annotation is new authorship, not
because the original code is uncopyrighted.

## The matrix

Names for each Build × Comprehension combination. Rights is orthogonal.

|  | **C0 unknown** | **C1 identified** | **C2 explained** |
|---|---|---|---|
| **B0 copy** | blob | extract claim | documented, not re-encodable |
| **B1 reproduce** | scaffold | described data | adopted |
| **B2 modify** | — | editable data | editable and documented |

## Glossary

- **Adopted** — a region at `reproduce`/`explained`.
- **Blob** — a region extracted verbatim with no claim beyond its extent
  (`copy`/`unknown`). A blob is correct, not explained.
- **Build path** — the path that produces ROM bytes. Must round-trip exactly.
- **Byte-exact** — bit-identical to the corresponding gold bytes.
- **Coincidental match** — bytes matching gold without being claimed (zero-fill,
  lucky collisions). Not a claim and not progress.
- **Evidence-earned name** — a name backed by trace data, disassembly at named
  offsets, or a byte-level argument.
- **Extract claim** — a region whose format and layout are claimed but whose
  content is read from gold at build time (`copy`/`identified`).
- **Gold gate** — the round-trip check used as referee.
- **Gold master** — the user's own legally dumped ROM; the source of truth for
  every byte. Never committed.
- **Manifest** — the declarative description of every region. Drives extraction
  and rebuild as inverse readings of one file; also serves as the linker config.
- **Modified build** — a build with opt-in changes. Byte-exactness does not
  apply; the emulator is the referee.
- **Region** — a contiguous span of the ROM covered by one manifest entry.
- **Round-trip** — `extract(gold)` followed by `build()` reproducing gold
  exactly.
- **Scaffold** — generated code that assembles byte-exact but has not been read
  (`reproduce`/`unknown`).
- **Vanilla build** — a build that must be byte-identical to gold.
- **View path** — renders regions into modern files (PNG, WAV, text) for humans.
  May be lossy or one-way; does not feed the build.

## Related

- [`decompilation-phase2.md`](decompilation-phase2.md)
- [`phase2-checklist.md`](phase2-checklist.md)
- `AGENTS.md` → Copyright hygiene · [`copyright-notes.md`](copyright-notes.md)
