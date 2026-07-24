# ROM chunks — full-image inventory for sub-agents

**Status:** live. **Updated:** 2026-07-24.

The 3 MB gold image is partitioned into **non-overlapping chunks** covering every
file byte. Sub-agents verify **one chunk** against the local baserom without
running a full `make compare`.

## Kinds

| Kind | Source | Done when |
|------|--------|-----------|
| `implemented_code` | `allRegions()` code / adoptions | Project-built bytes match gold for the span. Counts as decompiled progress. |
| `implemented_meta` | header, reset vectors | Declared data matches gold. |
| `unclaimed` | residual gaps | **Not** decompiled progress. Future: reclassify as code (disasm) or data (extract to gitignored paths only). |

Copyrighted ROM **content** is never committed. Gold is read only from
`bin/Earthbound (U) [!].smc` (gitignored) at check time.

## Commands (agent brief)

```bash
# Inventory
nim r src/tools/chunk_check.nim summary
nim r src/tools/chunk_check.nim list --kind implemented_code
nim r src/tools/chunk_check.nim list --kind unclaimed

# Verify one chunk (exit 0 + "OK match" for implemented)
nim r src/tools/chunk_check.nim check <chunk_id>

# All implemented chunks
nim r src/tools/chunk_check.nim check-all-implemented

# Or make wrappers
make chunk-summary
make chunk-check CHUNK=header
make chunk-check-all
```

**Exit codes:** `0` match / unclaimed report / list; `2` mismatch; `3` no gold.

## Module

- `src/decompbound/rom_chunks.nim` — partition + `checkChunkAgainstGold`
- `src/tools/chunk_check.nim` — CLI
- `tests/test_rom_chunks.nim` — structural + live gold

Whole-ROM progress remains `make compare` / `report.md` (must not fall).
