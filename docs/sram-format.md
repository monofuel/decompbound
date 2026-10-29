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
| `$09A` | 6 | Current game/HUD party order (1-based IDs) | original `$C21043`, six-slot bound `$C24CCD` |
| `$0CF` | 1 | Current game/HUD party count | original `$C2107A` |
| `$0B6` | 6 | Overworld walking identities | separate array `$988B`; count at slot `+$0CE` |
| `$1F8` | 1 | Window flavor, one-based 1–5 | original `$C47FCF`, live `$99CD` |
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
| `$0E`–`$14` | 7 | Condition groups | original `$C223D9` / `$C22474`; icon/palette selection verified |
| `$15`–`$1B` | 7×u8 | OFF/DEF/SPD/GUT/LUC/VIT/IQ (with equip) | community + sane midgame |
| `$1C`–`$22` | 7×u8 | Same stats, base (no equip) | community + sane midgame |
| `$23` | 14 | Inventory item IDs | confirmed |
| `$31`–`$34` | 4 | Equipment (1-based inv slot indices) | confirmed as indices; slot *names* soft |
| `$35` | 14 | PSI-learned bit table (raw) | candidate |
| `$43` | 2 | HP display fraction; bit 0 also gates rolling | original `$C2109F` + generated-state oracle |
| `$45` | 2 | Rolling HP integer (display) | original `$C21108` / `$C21164` |
| `$47` | 2 | Current/settled HP; target during rolling | confirmed |
| `$49` | 2 | PP display fraction; bit 0 also gates rolling | original `$C2109F` + generated-state oracle |
| `$4B` | 2 | Rolling PP integer (display) | original `$C21247` / `$C21345` |
| `$4D` | 2 | Current/settled PP; target during rolling | confirmed |
| `$4F` | 2 | Status-frame palette attributes | original `$C203C3`; `$0C00` selects incapacitated treatment |
| `$57`–`$5B` | 5 | Capsule boosts SPD/GUT/VIT/IQ/LUC | community |

The display/target distinction is verified against original ROM execution for
all four playable identities; see [EarthBound DS meter evidence](earthbound-ds.md#live-meter-evidence).
The existing SRAM/live-party APIs retain their settled-value semantics.

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
