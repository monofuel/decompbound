# Inventory & items

How item storage works, per character and party-wide.

## Per-character inventory: 14 slots

✅ **decomp-verified:** each playable character has **14 inventory slots**, a
flat array of item-ID bytes at character-record offset `+$23` (`0` = empty
slot). Same layout live in WRAM (`$99CE` + `$5F`×char) and persisted to the
battery save — see `docs/sram-format.md`. Parsed by `party_sram.nim` /
`party_wram.nim`; exposed per member as `inventory` on the MCP
`get_party_vitals` tool.

Slot numbering is 1-based in game terms (slot 1 = top of the bag).

## Equipment is an index into the bag

✅ **decomp-verified:** the four equip fields at record `+$31..$34` do **not**
hold item IDs — they hold **1-based inventory slot indices** (0 = nothing
equipped). Equipped items therefore still occupy one of the 14 slots; a fully
equipped character (weapon/body/arms/other) has only 10 free slots.

Consequences worth knowing:

- Equipment is *part of* the bag, so "inventory full" includes worn gear.
- 🟡 The *order* of the four fields (weapon/body/arms/other) is soft —
  confirmed as indices, slot-name assignment not individually verified.
- The bottom-of-bag position matters for the condiment glitch
  ([[known-bugs]]), which exploits inventory ordering.

## Party-wide storage

| Storage | Size | Where | Status |
|---------|------|-------|--------|
| Character bag | 14 ×u8 item IDs | char record `+$23` | ✅ |
| **Escargo Express** | **36 slots** — u8 item IDs at save-slot offset `+$76` | slot data, not per-char | ✅ offsets (`sram-format.md`); not yet on the MCP tool |
| Key items | flags/IDs, believed inside the persist block | ❓ unpinned | 🟡 |

## Item identity: the ROM item table

✅ **decomp-verified** (`docs/decompilation.md`): the item table lives at SNES
`$D55000` / file `0x155000`, `0x27`-byte records indexed `id × 0x27`:

| Record offset | Field |
|---------------|-------|
| `+$00` | Name, EB-encoded text (ASCII + `$30`), null-terminated |
| `+$19` | Type / equip-flag byte (soft — not a clean sellability mask) |
| `+$1A` | Price, u16 LE (buy price; also inputs sell offer) |
| `+$1C`… | More equip fields — still soft |

`src/decompbound/item_table.nim` decodes names/prices at runtime from the
user's ROM (never baked into source — copyright). Example IDs: `0x11`
Cracked bat, `0x1A` Gutsy bat, `0xB1` ATM card.

Shop inventories reference this table by ID (66 shops × 7 slots at file
`0x1578B2`); prices come from the item table, not per-shop.

## Shop sell rule

✅ **decomp-verified** (`docs/decompilation.md`, 2026-07-27):

| Claim | Evidence |
|-------|----------|
| Sell offer = floor(buy price / 2) | Sell helper `$C14F33`: load `+0x1A` then **`LSR A`** at `$C14F5A`. Buy twin `$C14EF8` loads the same field without shift. |
| Key/story items not worth selling | Sampled key IDs (ATM card, Sound Stone, Key to the tower, …) all have **price 0** in our ROM → sell offer 0. Franklin badge (id1) also price 0, type `$00`. |
| `sellable` for co-pilot | MCP inventory exposes `price`, `sellPrice` (= `price >> 1`), `sellable` (= `price > 0`). Safe to sell leftovers when `sellable` is true (e.g. salt packets); keep story keys when false. |

🟡 A dedicated sell-menu bit in `+0x19` (if one exists beyond price) is not
yet traced — type byte alone does not separate sellable from key (Show
ticket / Meteotite are priced with key-like high nibbles).

## Related

- [[stats]] — equipment feeds the equipped-stat bytes (and the 255 cliff).
- [[known-bugs]] — condiment glitch depends on bag ordering.
- `docs/sram-format.md` — byte-level record map.
- `docs/mcp-server.md` — `inventory` on `get_party_vitals`.
