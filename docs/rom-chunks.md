# ROM chunks — full-image inventory for sub-agents

**Status:** live. **Updated:** 2026-07-24.

The 3 MB gold image is partitioned into **non-overlapping chunks** covering every
file byte. Sub-agents verify **one chunk** against the local baserom without
running a full `make compare`.

## Memory safety

`list` / `summary` use **metadata only** (`generated/code_spans.nim` + adopted
sizes + header/vectors). They do **not** import bank modules or assemble.
`check` fills built bytes from `bin/Decompbound.smc` (run `make build` first).
That keeps agent inventory cheap when the generated tree is multi-megabyte.

## Kinds

| Kind | Source | Done when |
|------|--------|-----------|
| `implemented_code` | `code_spans` + snes_src adoptions | Decomp image matches gold for the span. Counts as decompiled progress. |
| `implemented_meta` | header, reset vectors, dispatch tables, baserom extracts | Declared/extracted data matches gold. |
| `unclaimed` | residual gaps | **Not** decompiled progress. Future: reclassify as code (disasm) or data (extract to gitignored paths only). |

Copyrighted ROM **content** is never committed. Gold is read only from
`bin/Earthbound (U) [!].smc` (gitignored) at check time.

## Commands (agent brief)

```bash
# Inventory (cheap — no bank assemble)
nim r src/tools/chunk_check.nim summary
nim r src/tools/chunk_check.nim list --kind implemented_code
nim r src/tools/chunk_check.nim list --kind unclaimed

# Verify one chunk (needs make build first; exit 0 + "OK match")
nim r src/tools/chunk_check.nim check <chunk_id>

# All implemented chunks
nim r src/tools/chunk_check.nim check-all-implemented

# Or make wrappers
make chunk-summary
make chunk-check CHUNK=header
make chunk-check-all
```

**Exit codes:** `0` match / unclaimed report / list; `2` mismatch / missing decomp; `3` no gold.

## Module

- `src/decompbound/rom_chunks.nim` — partition + meta inventory + gold check
- `src/decompbound/baserom_extract.nim` — gold-slice data claims (offset/length only; bytes from local baserom)
- `src/tools/probe_gap_formats.nim` — probe unclaimed gaps for gfx_lz / APU package
- `src/decompbound/generated/code_spans.nim` — offset/length only (from convert_all)
- `src/tools/chunk_check.nim` — CLI
- `tests/test_rom_chunks.nim` — structural + live gold

Whole-ROM progress remains `make compare` / `report.md` (must not fall).
