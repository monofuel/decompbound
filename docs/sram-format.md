# EarthBound SRAM (battery save) format — mapped so far

The save is 8KB (`$0000-$1FFF`), persisted by `play.nim` to a gitignored
`<rom>.srm`. Inspect it with `make sram` (or `src/tools/sram_info.nim`), and map
new fields with `make sram ARGS="--find <value>"`.

This is **partially** reverse engineered — offsets below are what we've
confirmed against a real early-game save (Ness lv2: 39/39 HP, 10/10 PP, $20 on
hand, $64 ATM). Extend `KnownFields` in `sram_info.nim` as we map more.

## Confirmed / observed offsets

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| `$0000` | 20 | Signature `"HAL Laboratory, inc."` | Save-validity marker; presence = valid EB save |
| `$001C` | 4 | Checksum / stamp | `1d 39 18 9f` in the sample; not yet verified |
| `$0040` | ~24 | Character name(s) | EB text encoding (offset from ASCII; see [[text-log]]) — not decoded yet |
| `$005C` | 4 (u32 LE) | **Money on hand** | Confirmed = $20 |
| `$0060` | 4 (u32 LE) | **ATM balance** | Inferred = $64 (sits right after on-hand) |
| `$023E` | 2 (u16 LE) | **Char1 HP (current)** | Confirmed = 39 |
| `$0240` | 2 (u16 LE) | **Char1 HP (max)** | Confirmed = 39 |
| `$0244` | 2 (u16 LE) | **Char1 PP (current)** | Confirmed = 10 |
| `$0246` | 2 (u16 LE) | **Char1 PP (max)** | Confirmed = 10 |

## Structure observations (not yet pinned down)

- **Backup copy at `+$500`.** `--find 20` located money at `$05C` AND `$55C`
  (= `$05C + $500`). EB appears to store the save twice (primary + backup) for
  corruption protection. So fields likely mirror at `offset + $500`.
- **Per-character stat blocks, ~`$60` stride.** HP/PP-like 16-bit pairs recur
  around `$23E`, `$29E`, `$2FE`, `$35E` (≈`$60` apart), suggesting a party-member
  struct. The exact sub-offsets within blocks 2-4 aren't confirmed (the sample
  only validated block 1 = the active char), and the other blocks' values
  (30/30, 30/30, 107/40) may be other characters' defaults or another layout —
  needs `--find` against known second-character stats to pin down.

## How to map more

1. In-game, note a value (e.g. XP, a stat, item count, a flag).
2. `make sram ARGS="--find <value>"` — see where it lives.
3. Cross-check by changing it in-game, saving, and re-finding.
4. Add the confirmed offset to `KnownFields` in `sram_info.nim` + this table.

## Related

- `src/tools/sram_info.nim` — the inspector/finder.
- `src/tools/play.nim` — writes the `.srm` (battery save).
- [[text-log]] docs/text-log.md — the EB text encoding (needed to decode names).
