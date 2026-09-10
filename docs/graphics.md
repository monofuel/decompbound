# Graphics data format (decomp track)

**Status:** NOT STARTED (was a stub). A data-decompilation track — see the hub,
`docs/decompilation.md`.

Reverse-engineer how EarthBound stores its **visual assets** in the ROM: the
tiles, palettes, sprites, backgrounds, font, and window graphics — including
whatever **compression** the game uses. This is the format whose mystery
inspired the emulator work in the first place.

## What's in scope

- **Tiles / character data** — SNES planar bitplanes (2bpp / 4bpp / 8bpp).
- **Palettes** — CGRAM entries, 15-bit BGR555.
- **Sprites (OBJ)** — the overworld NPCs + player, battle enemy sprites; their
  tile + palette + frame/animation layout.
- **Backgrounds** — overworld map tilesets and the famously **layered, animated
  battle backgrounds** (the scrolling/warping psychedelic effects).
- **Font + window graphics** — the text-window tiles (shared with the scripts
  track, `docs/scripts.md`).
- **Title / logo graphics** — the EarthBound logo, "War Against Giygas" card.
- **Compression** — EB does not store all graphics raw; identifying and
  round-tripping the compression scheme is the crux of this track.

## The instrument: watch VRAM get filled

Rather than guess at ROM offsets, use the emulator (`docs/decompilation.md`):
set a watch on **DMA to VRAM/CGRAM** during a scene and record which ROM bytes
land where. That maps source bytes → on-screen tiles directly, and — critically
— captures the *decompressed* output next to the compressed source, which is how
you crack the compression.

## Round-trip verification (the ungameable part)

Per the hub's rule: for each graphic asset,
**`encode(decode(bytes)) == bytes`** against the gold ROM. A decoder that
renders a plausible-looking sprite proves nothing; re-encoding to the exact
original bytes (compression included) proves we understand the layout. Rendered
output can also be pixel-compared against an emulator frame as a secondary check.

## Components

1. **Tile/palette codecs** — planar bitplane ↔ pixels, BGR555 ↔ RGB. The easy,
   well-documented part; get round-trip green first.
2. **Compression codec** — identify the scheme (via the DMA-watch capture of
   compressed-in / decompressed-out pairs), then decode + re-encode byte-exact.
3. **Asset catalog** — where each graphic lives (offsets, dimensions, palette),
   grown outward from what the emulator observes being loaded per scene.
4. **`sprites_explore.nim`** — the silky browser that visualizes decoded tiles,
   palettes, and sprite frames (currently a one-line TODO stub).

## Findings so far (verified)

The sprite *output path* is mapped (the actual OBJ CHR + definition tables are
still open):
- **OAM DMA:** the NMI handler at SNES `$C08196` (file `0x8196`) DMAs the 544-byte
  OAM table (128 sprites × 4 + the 32-byte high table) from a WRAM buffer at
  `$000500` / `$000800` (double-buffered, selected by `$2C`) to the OAM data port
  `$2104`. Verified byte-exact.
- **Entity/sprite update loop:** `$C09470` walks the entity linked list (`$0A50`
  head) and drives each entity via the `$C09558` action-script engine — the same
  script dispatch as events/doors (`docs/scripts.md`). Animation is script-driven.
- **Still open (the graphics themselves):** the sprite-definition table (ID → CHR
  + palette + size + frame layout), the OBJ CHR location, and the routine that
  *builds* the OAM buffer from entity poses. These resisted static RE — best
  cracked by watching the OBJ CHR DMA during a known sprite (the emulator-as-
  instrument approach).

### Compression — CRACKED (verified byte-exact)

The graphics **compression scheme** — the crux of this track — is decoded. The
decompressor is at file `0x041AC1` (SNES `$C41AC1`); verified:
`b7 cc c9 ff d0 04 … 29 e0 c9 e0` = `LDA [$CC],Y; CMP #$FF` (terminate) `; AND
#$E0; CMP #$E0` (long-vs-short form). It's a custom **LZ/RLE** with ~8 commands:

- Command byte → command + length. **Short:** `cmd = byte >> 5`,
  `len = (byte & 0x1F) + 1`. **Long** (when `byte & 0xE0 == 0xE0`):
  `cmd = (byte >> 2) & 7`, `len = ((byte & 3) << 8 | next_byte) + 1`.
- Commands: `0` literal run · `1` 8-bit RLE · `2` 16-bit RLE · `3` increasing
  sequence (`base + i`) · `4/7` backref (16-bit **BE** offset, copy forward) ·
  `5` rotated backref (bit-reversed bytes) · `6` reverse backref (copy backward).
- `0xFF` terminates the stream.

Example: the compressed graphic at file `0x214EE0` decodes to 1179 bytes
(`0C 0D 0E 0F 00 00 …`), confirmed by an independent decoder matching the ROM
routine. This codec unlocks **both** the graphics catalog *and* the maps track's
tilesets. (Some paths use an uncompressed far-copy at `~0x008ED2`.) Round-trip
DoD next: a byte-exact matching `pack` (encoder).

### Asset catalog (verified byte-exact)

Concrete located graphics (all `gfx_lz`-compressed; decode confirmed):
- **Battle enemy sprites** — via the enemy record's two 3-byte far gfx pointers
  (`+0x0C` / `+0x0F`). Pogo Punk (record `0x15C6DE`): `$EF78B8` → file `0x2F78B8`
  (863 → 3673 bytes, 114 tiles @4bpp) and `$6D9600` → file `0x2D9600` (295 → 2306,
  72 tiles). So `sprites_explore` can render any enemy straight from its record
  pointer.
- **Tilesets** — `0x3E408` (verified) + small compressed candidates nearby (e.g.
  `0x03ED00`); larger overworld sets share the maps load path (some uncompressed
  via the `~0x008ED2` far-copy).
- **Still open:** the player (Ness) + NPC **overworld** OBJ CHR + the
  sprite-definition table + sprite composition (buffer initialization is explained
  below) — the entity-gfx path is script-driven
  (`$C09470` + `gfx_lz` calls), no static table isolated; best cracked by watching
  the OBJ-VRAM DMA during an overworld load.

## Definition of done

- [ ] Tile + palette codecs round-trip byte-exact against gold.
- [ ] The graphics compression scheme is decoded **and** re-encoded byte-exact.
- [ ] A growing catalog of located assets (font, player/NPC sprites, a battle
      background) decoded and viewable.
- [ ] `sprites_explore.nim` browses decoded graphics on silky.

## Non-goals

- Re-drawing or modifying assets — this is *reading* the format, not romhacking.
- Re-implementing the PPU compositor (that's the emulator, Goal 2).

**Scope:** data RE + codecs + a silky explorer. Feeds the maps track (shared
tileset decoding) and cross-checks the emulator's PPU. Parallel-safe.
</content>

## OAM build initialization

`initializeOamBuild` at `$C088B1`, file `[0x0088B1, 0x008B19)`, is adopted
as [annotated assembly](../asm/initializeOamBuild.asm). It prepares sprite
output in WRAM; it does not decode graphics or transfer tiles to VRAM.

The routine clears the four 16-bit sprite queue counts at `$2504`, `$2606`,
`$2708`, and `$280A`. Selector word `$002E` chooses a build buffer:

| Selector | Low OAM table | High OAM table | Low-table entries |
|---|---|---|---|
| 1 | `$0500` | `$0700` | 128 × 4 bytes |
| Any other value | `$0800` | `$0A00` | 128 × 4 bytes |

It installs the low-table cursor at `$0003`, its end at `$0005`, and the
high-table cursor at `$0007`. Byte `$000A` is initialized to `$80` for the
subsequent high-bit packing algorithm. That packer's full contract is a
separate investigation.

Each low-table entry's Y byte (offset 1) becomes `$E0`, outside the visible
224-line area. X, tile number, attributes, and the high table are deliberately
left unchanged. Two unrolled groups of 64 stores temporarily move direct
page across the two 256-byte pages; the original direct page is restored.
The other build buffer and selector are untouched.

Native-mode callers supply DBR `$7E`, so absolute accesses and bank-zero
direct-page accesses address the same WRAM buffers. The routine preserves DBR,
direct page, Y, stack depth, and carry/decimal/overflow flags. It returns
with 16-bit A/X, A's low byte `$E0` (high byte preserved), and X holding the
high-table base. The next routine starts at `$C08B19`; it is not part of this
adopted span.

`nim r tests/integration_oam_build.nim` compares all 616 assembled bytes
with the original ROM and executes the ROM routine for five selectors,
three initial accumulators, and all 256 native processor-status combinations
(3,840 calls). It checks both complete buffer areas, all four counts, build
pointers, selector preservation, and the stated register contract using only
synthetic RAM. This passed on 2026-09-10; `make compare` remains byte-identical.

### Connection to the frame service and next graphics question

The normal branch of `$C1004E` calls the initializer at `$C10067`, then
`$C09466` (entity processing), `$C08B26` (compose/publish), and `$C08756`
(wait and refresh input). The `$9643 != 0` branch instead calls `$C43568`.
Entity processing crosses to bank `$80` via `JML $809470`; instruction traces
must account for that bank alias when looking for callbacks.

Static inspection locates queued-sprite composition at `$C08B8E` and the
per-sprite emitter at `$C08CD5`. These are concrete entry points, not yet
adopted complete explanations. The emitter's verified record semantics and the
queue's statically derived layout follow below. Definition producers and their
graphics references remain the link needed for a faithful asset browser.

## Sprite-element emission

The emitter at `$C08CD5..$C08D78` consumes a definition at A in the bank
specified by byte `$000B`, with X/Y as origin coordinates. It switches direct
page to zero and preserves the caller's direct page, DBR, and processor status.
The verified coordinate contract uses native mode with decimal arithmetic off.
It is not yet adopted as reproduced assembly in the manifest.

Ordinary records are five bytes:

| Offset | Meaning |
|---|---|
| 0 | Signed Y displacement; `$80` instead introduces a redirect |
| 1 | OAM tile low byte |
| 2 | OAM attributes, including tile high bit |
| 3 | Signed X displacement |
| 4 | Bit 0: OAM size bit; bit 7: last element; other bits do not affect emission |

A redirect consists of `$80` followed by a little-endian word naming another
position in the same bank. It emits no sprite. There is no cycle detection.
For ordinary records, arithmetic wraps at 16 bits:

- `screenY = originY + signed(dy) - 1`. Accepted Y values are `-32..223`.
- `screenX = originX + signed(dx)`. Accepted X values are `-256..255`.
- These bounds do not change with the size bit; they are the routine's coarse
  rejection rules, not a guarantee that the PPU displays a visible pixel.

The low-table cursor/end are words `$03/$05`. Y rejection writes no sprite
bytes. After Y passes, tile/attributes and low X are written **before** X
rejection. Thus an X-rejected element leaves partial bytes at the current slot,
without advancing the cursor or replacing its Y. A later accepted element
can overwrite that slot. The last-element flag ends processing even when the
record is rejected. Capacity is checked at entry and after each accepted record.

For an accepted sprite, X bit 8 and record bit 0 are shifted into the byte at
`$0A`. After four sprites, bits 0/1 describe the first sprite's X-high/size,
bits 2/3 the second, and so on. The byte is written through long pointer `$07`,
its low address byte is incremented, and `$0A` resets to sentinel `$80`.
A partial group remains pending in `$0A`; the emitter does not flush it on
return. This pointer increment is byte-wide, so callers must supply an OAM
high table that does not require a page crossing during the group writes.

Evidence: original instructions at file `0x008CD5`, including the Y check at
`0x008D12`, X check at `0x008D3E`, and packed-bit writes at `0x008D4B`.
Disassemble `0x008D28` separately with M16: a linear disassembly that carries
M8 from the rejected-Y branch misdecodes that branch target.

`nim r tests/integration_oam_emit.nim` runs original ROM code against synthetic
WRAM definitions. It checks 12,264 single-element cases across all ordinary
byte displacements, 12 boundary/wrap origins, and both size bits; a four-sprite
packing/capacity case; a same-bank redirect; and an initially full buffer.
An additional sequence rejects one record on Y and another on X before accepting
a final record into the original slot, including ignored flag bits 1–6.
It verifies partial writes and untouched bytes as well as accepted output.
These are CPU/memory checks, not a visual fidelity claim or exhaustive caller
coverage. Decimal mode, malformed definitions, and the complete range of caller
processor-width combinations remain outside this test's contract.

### Queue connection

Static inspection of `$C08B8E` shows four queues drained in order. For queue
bases `$2404`, `$2506`, `$2608`, and `$270A`, parallel word arrays hold definition
pointers at `base+$00`, origin X at `base+$40`, origin Y at `base+$80`, and bank
words at `base+$C0`. Each array has room for 32 entries. The word at `base+$100`
is a byte count: the drain's index advances by two for each entry. Counts are
not cleared by the drain; initialization clears them before entity processing.
The bank word is copied to `$000B/$000C`; the emitter reads only its low byte.

This layout is static evidence, pending an enqueue-to-drain behavioral test.
Next: verify that integration, explain partial high-table flushing in `$C08B26`,
and follow definition producers to their graphics and palette references.
