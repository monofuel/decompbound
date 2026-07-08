# EarthBound SRAM (battery save) format — mapped so far

The save is 8KB (`$0000-$1FFF`), persisted by `play.nim` to a gitignored
`<rom>.srm`. Inspect it with `make sram` (or `src/tools/sram_info.nim`), and map
new fields with `make sram ARGS="--find <value>"`.

This is **partially** reverse engineered. Offsets below mix local `--find`
confirmation on real saves with community cross-refs (datacrystal character
table / Oh Mother editor). Confidence is labeled in `sram_info.nim` output.

## File layout

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| `$0000` | `$500` | Save slot 1A | Signature + checksums + data |
| `$0500` | `$500` | Save slot 1B | Mirror of 1A (corruption canary) |
| `$0A00` | `$500` | Save slot 2A | |
| `$0F00` | `$500` | Save slot 2B | |
| `$1400` | `$500` | Save slot 3A | |
| `$1900` | `$500` | Save slot 3B | |
| `$1FF0` | 1 | Anti-piracy byte | Expect `$31` on US carts |
| `$1FFE` | 2 | Region/version | `$0493` US |

Each `$500` block:

| Rel | Size | Field |
|-----|------|-------|
| `$00` | 20 | Signature `"HAL Laboratory, inc."` |
| `$1C` | 2 | Checksum 1 (also used as stamp heuristic) |
| `$1E` | 2 | Checksum 2 |
| `$20` | `$4E0` | Save data (WRAM persistent block mirror) |

## Slot-relative data offsets (from block base, *not* data-only)

| Offset | Size | Field | Confidence |
|--------|------|-------|------------|
| `$044` | 6 | Pet name (EB text) | confirmed decode (King) |
| `$04A` | 6 | Favourite food | confirmed (Steak) |
| `$054` | 6 | Favourite thing | confirmed (Rockin) |
| `$05C` | 4 u32 LE | **Money on hand** | confirmed across saves |
| `$060` | 4 u32 LE | **ATM balance** | confirmed across saves |
| `$076` | 36 | Escargo Express item IDs | confirmed |
| `$0A2` | 2 | Party leader X | community only |
| `$0A6` | 2 | Party leader Y | community only |
| `$0B6` | 7 | Party roster (1-based char IDs, 0=empty) | confirmed |
| `$1F9` | `$5F`×6 | Character table (4 playable + 2 reserved) | confirmed |

Data-relative form used by some tools: subtract `$20` (e.g. money `$3C`,
char table `$1D9`).

## Per-character entry (`$5F` bytes)

| Rel | Size | Field | Confidence |
|-----|------|-------|------------|
| `$00` | 5 | Name (EB text, ASCII+`$30`) | confirmed |
| `$05` | 1 | Level | confirmed |
| `$06` | 4 u32 LE | EXP | confirmed |
| `$0A` | 2 | Max HP | confirmed (matches full HP) |
| `$0C` | 2 | Max PP | confirmed |
| `$15`–`$1B` | 7×u8 | OFF/DEF/SPD/GUT/LUC/VIT/IQ (with equip) | community + sane midgame |
| `$1C`–`$22` | 7×u8 | Same stats, base (no equip) | community + sane midgame |
| `$23` | 14 | Inventory item IDs | confirmed |
| `$31`–`$34` | 4 | Equipment (1-based inv slot indices) | confirmed as indices; slot *names* soft |
| `$35` | 14 | PSI-learned bit table (raw) | candidate |
| `$45` | 2 | Rolling HP (display) | community |
| `$47` | 2 | Current HP | confirmed |
| `$4B` | 2 | Rolling PP | community |
| `$4D` | 2 | Current PP | confirmed |
| `$57`–`$5B` | 5 | Capsule boosts SPD/GUT/VIT/IQ/LUC | community |

## How to map more

1. In-game, note a value (e.g. XP, a stat, item count, a flag).
2. `make sram ARGS="--find <value>"` — see where it lives.
3. Cross-check by changing it in-game, saving, and re-finding.
4. Add the confirmed offset to `sram_info.nim` + this table with a confidence label.

**Still unmapped:** playtime, story flag meanings, PSI bit→move map, EXP table
is community (rpgclassics) not ROM-extracted.

## Related

- `src/tools/sram_info.nim` — inspector / report card / `--find` / `--out`.
- `src/tools/play.nim` — writes the `.srm` (battery save).
- `docs/apps.md` App 2 — save-file report card goals.
- [[text-log]] docs/text-log.md — the EB text encoding (needed to decode names).
