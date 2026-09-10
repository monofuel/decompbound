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
per-sprite emitter at `$C08CD5`. The emitter is adopted; the queue drain remains
unadopted. The emitter's verified record semantics and the
queue's statically derived layout follow below. Definition producers and their
graphics references remain the link needed for a faithful asset browser.

## Sprite-element emission

The emitter at `$C08CD5..$C08D78` consumes a definition at A in the bank
specified by byte `$000B`, with X/Y as origin coordinates. It switches direct
page to zero and preserves the caller's direct page, DBR, and processor status.
The verified coordinate contract uses native mode with decimal arithmetic off.
It is adopted as [annotated assembly](../asm/emitSpriteElements.asm), with all
164 bytes compared against the original ROM by the emitter integration test.

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

The layout and group/insertion order are verified by the original-ROM pipeline
test below. Queue capacity is inferred from the array spacing; enqueue has no
bounds check. Definition producers and their graphics/palette references remain
open.


## Queue-to-buffer publication

The long-call enqueue wrapper `$C08C54` calls `$C08C58`, which selects one of
four append handlers via word `$2400` and jump table `$C08C65`. It stores the
incoming A definition pointer, X/Y origin, and word `$000B` in parallel arrays,
then increments that queue's byte count by two. Native 16-bit indices are
required: the code pushes X and retrieves it with a 16-bit accumulator pull.
It forces M16 but does not force X16. Valid queue indices are 0–3, and each
queue has space for 32 records; neither limit is checked by the routine.

`publishOamBuild` at `$C08B26..$C08B8D` is adopted as
[annotated assembly](../asm/publishOamBuild.asm). Its 104 bytes are checked
against the original ROM by the pipeline integration test. It first calls the
queue drain at `$C08B8E`. Definitions are
emitted in queue order 0–3, preserving insertion order within each queue. This
can differ from the order in which entities enqueued them. Counts remain intact
after draining, so publication is not a queue reset.

Publication requires initialized cursors and a valid packing sentinel at
`$000A`; zero is invalid and would leave the alignment loop spinning. After
draining, publication finalizes the pending high-table byte. If `$000A`
is not the empty sentinel `$80`, it shifts right two bits at a time until the
sentinel exits through carry. For one/two/three pending sprites, this moves
packed pairs right by six/four/two bits. It then writes the result at the
address in word `$0007`, using DBR rather than the emitter's long-pointer bank.
Both accesses must refer to the same WRAM: the tested contract uses DBR `$7E`
and pointer bank `$00` or `$7E`.

The final store is **unconditional**. Zero sprites write `$80` at the high-table
base. A multiple of four sprites writes `$80` after the completed groups; with
128 sprites this is one byte beyond the 32-byte OAM high table. This is actual
ROM behavior, not an additional sprite or a requirement to transfer that extra
byte to the PPU. The final store does not modify `$000A` or advance `$0007`.

Publication then copies eight words from `$0031+2*i` to
`$0041+4*i+2*(selector-1)`, using selector word `$002E`. It writes the selector's
low byte to `$002C` and toggles the low byte of `$002E` with XOR 3. This selects
the other build buffer on the next initialization. The upper byte of `$002C`
is preserved. Valid selector words here are 1 and 2; the initializer's fallback
for other values does not imply that publication accepts them safely. These
are BG1–4 horizontal/vertical scroll snapshots, consumed as described below.

Evidence: original enqueue at file `0x008C54` and handler entry `0x008C6D`;
drain at `0x008B8E`; final store at `0x008B40`; snapshot and publication writes
at `0x008B48..0x008B8A`. The DBR `$FF` branch at `0x008B33` deliberately spins;
that path is outside the normal WRAM contract.

`nim r tests/integration_oam_publish.nim` verifies 258 full pipeline scenarios:
both buffers, each with 0–128 sprites. Each scenario runs original initialization,
enqueues synthetic definitions interleaved across all four queues, and runs
original publication. Assertions cover queue field layout, retained counts,
reordered output, every low-table entry, complete and partial packed bytes,
the extra sentinel byte, preserved pending accumulator, snapshots, selector
toggling, and the untouched alternate buffer. Each queue stays within its
32-record capacity. The two buffer cases also exercise long-pointer banks `$00`
and `$7E`. No game assets, frames, or machine-state fixtures are used.

The test also executes the bounded interrupt consumers below to establish the
PPU transfer. Full interrupt scheduling and visual fidelity remain outside its
scope. Entity definition pointers and graphics/palette selection remain open.


## Published buffer transfer and scroll snapshots

The shared interrupt handler consumes the pending byte `$002C`. The fragment
at `$C08196..$C081C7` runs with M16/X8, direct page zero, and DBR zero. Zero
means no pending OAM transfer; 1 selects bank-zero `$0500`, and other nonzero
values select `$0800`. The normal producer publishes only 1 or 2.

It resets both OAM address registers with a 16-bit store at `$2102`, then sets
DMA channel 0 to incrementing mode 0, destination `$2104`, source bank zero,
and length `$0220` (544 bytes). This transfers exactly the 512-byte low table
and 32-byte high table. The extra `$80` byte written after a completely full
high table by publication is **not transferred**. The fragment adds 544 to
word `$0099`, which accumulates transfer bytes in this handler.

Later, `$C08278..$C08337` consumes the associated scroll snapshots. For selector
1, words `$0041+4*i` supply successive low/high writes to register `$210D+i`;
for selector 2, words `$0043+4*i` do so. These eight ports are BG1 H/V, BG2 H/V,
BG3 H/V, and BG4 H/V. Thus publication preserves background scroll values
alongside the sprite buffer until interrupt-time application.

The second branch also copies current words `$0031/$0033` into `$0061/$0063`;
the first branch does not. The role of these additional copies is unresolved.
Finally, an 8-bit store clears `$002C`, preserving upper byte `$002D`. This
happens after scroll application, not immediately after OAM DMA. With no new
publication, the next visit skips both transfers. Other interrupt work still
runs and is outside this observation.

Original evidence: NMI entry `$C08170` establishes direct page and DBR zero;
OAM DMA begins at file `0x008196`; scroll application begins at `0x008278`;
consumption occurs at `0x008334`. These ranges are fragments of a larger
interrupt handler, not independently callable routines.

`tests/integration_oam_publish.nim` extends each of its 258 pipeline scenarios
with execution of those original fragments, stopping at `$C081C8` and
`$C08338`. It deliberately dirties the OAM address before transfer, verifies
all 544 resulting PPU OAM bytes and channel configuration, checks the exact 16
scroll-port writes and latched scroll values, and verifies the branch-specific
copies and pending-byte consumption. Re-execution with a cleared pending byte
must leave OAM/scroll state and the DMA count unchanged. This uses the actual
emulator bus and DMA implementation, with synthetic data only.

The test initializes the fragments' entry contracts directly. It does not yet
verify an entire NMI/IRQ entry/return, cycle timing, interactions with other
DMA channels, or how publication behaves if interrupted partway through.
