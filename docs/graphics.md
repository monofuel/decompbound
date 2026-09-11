# Graphics data format (decomp track)

**Status:** Partial. Overworld sprite allocation, definitions, uploads, and the
baseline palette have executable evidence and a local preview. Complete asset
identification, scene-dependent palettes, maps, and other graphics classes
remain open. See [GOAL.md](../GOAL.md) for completion criteria.

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

The sprite output path and normal overworld resource path are mapped below:
- **OAM DMA:** the NMI handler at SNES `$C08196` (file `0x8196`) DMAs the 544-byte
  OAM table (128 sprites × 4 + the 32-byte high table) from a WRAM buffer at
  `$000500` / `$000800` (double-buffered, selected by `$2C`) to the OAM data port
  `$2104`. Verified byte-exact.
- **Entity/sprite update loop:** `$C09470` walks the entity linked list (`$0A50`
  head) and drives each entity via the `$C09558` action-script engine — the same
  script dispatch as events/doors (`docs/scripts.md`). Animation is script-driven.
- **Resource coverage:** 464 resource-table entries link to layout definitions
  and CHR sources. Normal frame selection and baseline palette publication are
  verified below. Identity labels, scene overrides, and a complete inventory of
  other graphics classes remain open.

### Local overworld sprite preview

Run `nim r src/tools/sprite_preview.nim 437 0 0` for resource ID 437,
direction selector 0, phase 0. The arguments default to those values; accepted
ranges are resource 0–463, direction 0–7, and phase 0–1. Output is
`extracted/view/sprites/437-0-0.png`, always under the ignored extraction tree.
These images contain game graphics and must remain local.

The preview executes the original allocation/header reader, definition builder,
frame upload, baseline palette copy, priority callback, OAM publication, and
interrupt DMA fragments in an isolated emulator. It uses OBSEL `$62`, full
brightness, no scene effects, and origin (128,112). This produces a normal
overworld-resource preview, not a captured scene or a battle-enemy browser.
The palette is the baseline at `$C30000`; scene overrides remain outside its
contract. No game assets are embedded in the tool.

`tests/integration_sprite_preview.nim` compares OAM attributes/positions and
rendered pixels against a separate model reading the ROM's selected layout,
decoding uploaded planar tiles, and reading baseline palette colors. It covers
all 464 resources at selector/phase 0 plus the other 15 combinations for 19
representative resources (749 cases). This composition check complements the
independent allocation, upload, and palette tests; both pixel paths still share
our emulator's VRAM. Visual comparison against game execution remains in
[human verification](human-verify.md).

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
- **Still open:** complete player/NPC OBJ CHR and palette mapping. The resource
  and layout tables are located below, together with verified sprite composition.
  Correlating those resources with OBJ-VRAM transfers during an overworld load
  remains necessary for a faithful catalog.

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


## Entity frame tables and action-script configuration

One entity rendering callback, `$C0A0FA..$C0A11A`, treats A as a frame index
into a table of 16-bit definition pointers sharing the table's base bank. It doubles A, reads the
word through long pointer `$8C`, and enqueues that selected definition using
entity queue group `$103E,X` and origin words `$0B8E,X` / `$0BCA,X`. The table's
bank byte at `$8E` becomes the definition bank at `$000B`; the neighboring
byte `$000C` is preserved. Tile and attribute bytes come from the selected
five-byte definition records, unchanged by this callback.

The preceding dispatch at `$C0A0E3` loads the table address from entity word
`$112E,X` and the bank/state word from `$116A,X`. It loads `$10F2,X` as the
callback's A input, rejecting negative values, then jumps indirectly through
entity callback word `$11E2,X`. For the `$A0FA` callback this makes `$10F2` a
**frame index**, not merely a timer. Other callbacks may interpret it differently.
Entity arrays here use byte offsets into word arrays (`X = entity index * 2`).

Action-script opcode `$1C` installs the pointer: handler `$C09B4D` reads a
three-byte operand, stores its word at entity `$112E,X` and its bank byte at
`$116A,X`, preserving the neighboring high state byte. Opcode `$22`, handler
`$C09BE4`, installs the two-byte callback address at `$11E2,X`. Both obtain the
entity offset from direct-page `$88`; their input stream is long pointer `$80`
with Y already at the operands. These are action-VM opcodes, not dialogue codes.

The normal dispatch rejects a negative bank/state word and also branches on
**inherited overflow** at `$C0A0E8`: its preceding LDA does not update V.
Do not reinterpret that branch as a test of bank/state bit 14. The test below
uses a positive bank/state word and V clear; meanings of the upper state bits
and all suppression paths are not yet established.

`nim r tests/integration_entity_sprite.nim` checks 8,640 synthetic scenarios:
30 entity offsets, four queue groups, two RAM banks, and 36 frame indices
(0–31, 127, 128, 255, 256). It verifies the two opcode dispatch-table entries,
executes their original handlers with synthetic operands, then runs original
entity dispatch, table lookup, enqueue, and publication. Checks include operand
advancement, preservation of the high bank/state byte, selected table word,
queue bank and coordinates, and resulting tile/attribute/size/position in OAM.
No ROM graphics or script bodies are embedded. The action-VM fetch loop itself
is not executed by this test; the handlers receive its documented entry state.

This proves the configured table-based path. It does not inventory all frame
tables, explain how CHR is uploaded, or prove palette selection for every entity.
Other callbacks can construct or modify definitions instead of indexing this
table. Next: distinguish those callback families and link their definition
sources to actual graphics and palettes.

## Default callback: two priority groups

The default callback at `$C0A3A4..$C0A442` operates on a writable definition,
rather than looking up a frame pointer like `$A0FA`. If entity word `$341A,X`
has bit 0 set, it adds word `$2916,X` to the definition pointer's low word at
DP `$8C`. This selects another definition region without changing its bank.

It patches two consecutive groups of five-byte records. Byte `$2BE7,X` counts
the first group and byte `$2BE6,X` counts the second. For each record, only
attribute bits 4–5 change:

| Group | Control bit in `$2BAA,X` | Bit clear | Bit set |
|---|---|---|---|
| First | 1 | `(attribute & $CF) | $30` | `(attribute & $CF) | $20` |
| Second | 0 | `(attribute & $CF) | $30` | `(attribute & $CF) | $20` |

These are OAM priority bits. Palette bits, tile-high bit, and flips are preserved.
Both loops use 8-bit indices; the verified small-group cases below do not imply
that arbitrary large counts or definitions crossing a 256-byte indexing window
work. After patching, the callback resolves a queue group, calls overlay helper
`$C0AC43`, then enqueues the direct definition pointer using screen-position
words `$0B16,X` and `$0B52,X`.

`nim r tests/integration_sprite_priority.nim` verifies 12,288 scenarios for
entity offset zero: every attribute byte, all four priority-control combinations,
six first/second group-count pairs, and both pointer-offset choices. It executes
the complete original callback with overlays inactive (`$2BAA & $0C = 0` and
`$2E7A = 0`), then original publication. It checks all 512 bytes spanning both
synthetic definition regions for unintended writes and checks resulting OAM
positions, tile bytes, attributes, and emitted count. Either group may be empty;
the combined record list is nonempty and terminated.

The test uses direct page `$0200` for entity scratch. This matters: the overlay
helper uses DP `$00..$08`, while global OAM pointers live at absolute `$0003`
and nearby addresses. Using direct page zero for this complete callback would
alias unrelated scratch and OAM state. Overlay-producing paths and indirect
queue-group references are not yet covered by this test.

## Resource and layout tables: static route into runtime definitions

Original code now supplies concrete table addresses for the default path:

| Source | Selection | Evidence |
|---|---|---|
| `$EF133F` (file `0x2F133F`) | Four-byte resource-pointer slots indexed by resource ID | `$C01E79..$C01E96` |
| `$C42B0D` (file `0x042B0D`) | Four-byte layout-pointer slots indexed by layout ID | `$C01EBE..$C01EDB` |

The resource lookup helper `$C01DED` supplies the layout ID. Initialization
reads layout byte 0 as a record count and requests ten bytes per record at
`$C01EE9`. It passes resource byte 3 and the selected layout to builder
`$C01D38` at `$C01F27`. Later it installs the runtime definition at WRAM
`$467E + allocationOffset` into entity `$112E`, with bank `$7E` in `$116A`.

The count split is visible at `$C020A4..$C020C6`: layout byte 1 becomes the
first-group count in `$2BE7`; `(layout byte 0 - layout byte 1) & $FF` becomes
second-group count `$2BE6`. This connects the layout header to the priority
loops, rather than treating their counts as unrelated entity state.

These are **static findings**, not a completed resource catalog. Table lengths,
valid ID ranges, complete layout records, allocation behavior, graphics frame
pointers, and palette interpretation remain to be verified. The runtime-definition
builder is verified below. Next: correlate a real resource's layout with its
generated records and graphics transfer. Keep extracted resource
and layout contents local; only the code, structural facts, and evidence belong
in the repository.

## Runtime-definition builder

`buildSpriteDefinitions` at `$C01D38..$C01DEC` is adopted as
[annotated assembly](../asm/buildSpriteDefinitions.asm), with all 181 bytes
checked against the original ROM. It converts a layout into **two consecutive variants** of
five-byte sprite records. Inputs are A = output allocation offset, X = tile
allocation slot, Y = resource attribute modifier. The caller supplies a long
layout pointer at direct-page offset `$0E`; DBR selects WRAM `$7E`, and decimal
mode must be clear. The routine moves direct page down by `$1A` for local scratch
and restores it on return.

The source consists of a two-byte header followed by `2 * count` five-byte
records, where count is header byte 0. Header byte 1 is skipped here; entity
initialization uses it separately for priority groups. Source records continue
sequentially from the first variant into the second. The tile-allocation element
index restarts at zero for the second variant.

For variant `v` and element `i`, the output starts at
`$7E467E + allocationOffset + 5*(v*count+i)`. The tile word is read from
`$C4303C + 2*(tileAllocationSlot+i)`:

| Output byte | Source |
|---|---|
| Y displacement | Layout record byte 0 |
| Tile low byte | Tile-map word low byte |
| Attributes | `(layout byte 2 & $FE) | resourceModifier | tile-map word high byte` |
| X displacement | Layout record byte 3 |
| Size/end flags | Layout record byte 4 |

Layout record byte 1 is unused by this builder. Resource attributes are ORed,
not substituted into a masked palette field; interpreting resource byte 3 solely
as a palette number would discard part of the actual operation. The routine
copies size/end flags as supplied and does not synthesize list termination.

A zero count produces no output. For count `n`, return values are A=`n`, Y=2,
and X=`allocationOffset+10*n` (16-bit); M/X are 16-bit, while DBR, direct page,
and caller stack depth are preserved. Source cursor increments update only its
low word, leaving the bank unchanged. A layout crossing that address boundary
cannot be treated as a contiguous 24-bit stream without further analysis.

`nim r tests/integration_sprite_layout.nim` verifies 32,000 original-ROM
executions: five counts including zero, five tile allocation slots, every
layout attribute byte, and five resource modifiers. Layouts are synthetic;
tile-map words are read at test time from the user's ROM. Assertions verify
both complete output variants, untouched surrounding bytes, tile-index restart,
ignored source byte 1, merged attributes, and the return contract. The test
enters the ROM routine with a synthetic same-bank return frame; it does not
patch executable ROM bytes or commit extracted data.

This establishes record construction independently of allocation, resource-ID
validation, or CHR transfer. Those surrounding mechanisms still need their own
evidence before claiming a complete asset loader or browse-all catalog.


## Real-resource layout checks and field correction

The existing research used 464 entries for the resource table at `$EF133F`.
Independent inspection supports that structural boundary: all 464 candidate
pointers target bank `$EF`, and their lowest target is `$EF1A7F`, exactly the
address after 464 four-byte entries. This is not evidence of a runtime bounds
check or permission to accept arbitrary resource IDs.

Those entries reference layout IDs 0–16. IDs 0 and 1 share one layout pointer,
so there are 16 distinct layout bodies in this set. Their per-variant record
counts range from 1 to 20. These are structural facts derived from the user's
ROM; no layout or resource payload is committed.

`tests/integration_sprite_layout.nim` now also runs the original builder for
all 464 resource entries at two tile-allocation slots (928 additional cases).
Each case follows the actual resource/layout pointers, uses resource byte 3 as
the attribute modifier, and compares both generated variants with the format
model. It checks group-count consistency, return values, and surrounding output
sentinels. The 32,000 synthetic cases remain alongside these real-input checks.
This executes the builder, not the allocator or complete resource loader.

An older description in the data-research hub called resource byte 8 a script
bank and resource offset 9 a script base. The original consumers establish a
graphics path instead:

- `$C01FD4..$C01FDD` stores resource byte 8 in entity `$2A42`.
- `$C0200E..$C02019` installs **resource address + 9** in `$29CA` and the resource
  bank in `$2A06`; this is an inline entry-list address, not a pointer read at +9.
- `$C0A53F..$C0A559` retains a selected entry in `$341A`, masks its low four bits
  off to form transfer source offset `$0094`, loads source bank `$0096` from
  `$2A42`, and calls the graphics-transfer path.

Script selection is separate: spawn `$C01E49` receives a selector in X and
passes it to `$C09321`. The latter indexes the three-byte table at `$C400D4`
and installs action-script address/bank fields `$13FE/$148A`. This separation
corrects the hub's field labels; it does not settle all graphics-entry flags or
all script behavior. Next: verify graphics-entry selection and transfer together
for a known resource, including how low-bit flags choose the definition variant.

## Sprite graphics transfer to VRAM

The selected graphics-entry word is retained in entity `$341A` by `$C0A53F`;
its address portion (`entry & $FFF0`) becomes source offset `$0094`. Source bank
comes from `$2A42` into byte `$0096`. This establishes the path from a resource's
inline entries to graphics bytes; the low bits remain available to the default
callback, whose bit-0 definition-offset choice is described above.

The public request helper `$C08643` uses these global fields:

| Address | Meaning |
|---|---|
| `$0091` byte | Offset into the three-byte DMA-profile table at `$C08FB0` |
| `$0092` word | Transfer size in bytes |
| `$0094` word | Source address within its bank |
| `$0096` byte | Source bank |
| `$0097` word | Destination VRAM word address |

Profile offset 0 selects incrementing mode-1 DMA to `$2118/$2119`, with VMAIN
`$80`. The helper temporarily sets direct page and DBR to zero and restores
processor status, direct page, DBR, and stack depth. It does not preserve A/X;
Y returns zero because it is used to establish DBR before the inner call.

If forced-blank shadow byte `$000D` has bit 7 set, the helper performs DMA
immediately on channel 1. Otherwise it appends an eight-byte record containing
`$0091..$0098` to the ring at `$0400`, using byte head/tail indices `$00/$01`.
The producer advances by eight modulo 256. The interrupt consumer at
`$C08238..$C08277` drains these records via channel 0 and advances the tail.
The two paths are expected to produce the same VRAM data for a given request.

Queued byte counts accumulate in `$0099`. The inner helper waits for interrupt
progress if adding a request exceeds `$1200` bytes or the ring would become
full. These waits are intentional; tests with no interrupt scheduling must
provide available space and budget rather than bypassing the waits.

Sprite wrapper `$C0A56E..$C0A60A` applies a placement rule before invoking that
helper. For the tested even sizes, if the destination range crosses a
`$100`-word boundary, the first transfer ends at that boundary and the second
starts another `$100` words later. Source bytes remain consecutive. The wrapper
restores the original source offset and byte count after splitting; it advances
`$0097` separately to prepare the next sprite segment. Destination advancement
is also checked: if the initial destination has bit 8 clear, add `$100`.
Otherwise add `32 * floor((size+32)/64)` words, then subtract `$100` if bit 8
is still set. This describes the tested small, even transfer sizes.
Oversized requests crossing multiple boundaries and source-bank wrapping remain
outside the verified scope.

`nim r tests/integration_sprite_dma.nim` verifies 256 synthetic scenarios:
eight destination positions, four byte sizes (32/64/128/256), two source banks,
two ring positions (including wrap from `$F8`), and queued/immediate modes. It
executes the original sprite wrapper and, for queued work, the bounded original
interrupt drain. It checks queue records, DMA counts, source/size preservation, next-destination advancement,
and every VRAM word, including the skipped region and untouched surroundings.

Sixteen further cases use resources 0, 44, 145, and 437, each with its first two
inline graphics entries and both transfer modes. They run original entry
decoding at `$C0A53F`, verify the retained flags/source address/bank, and compare
a 32-byte transfer against the user's ROM. This is a representative source-path
check, not a complete frame upload: the request size and destination are supplied
by the test, and upstream animation-entry selection is not executed. No graphics
bytes or screenshots are written to tracked files.

Full normal frame-transfer dimensions are verified below. Palette sources and
faithful scene assembly remain open.

## Full normal frame uploads

The initializer defines the request dimensions directly from the resource:
byte 0 becomes the chunk count at entity `$2ABA`; twice byte 1 becomes the
bytes-per-chunk value at `$2A7E` (`$C01FAD..$C01FC4`). The 464 candidate resources
contain 16 distinct count/size combinations, with counts from 2 to 10 and chunk
sizes from 64 to 256 bytes. This describes transfer dimensions, not necessarily
a rectangular image's pixel dimensions.

Initial VRAM word address `$298E` is `$4000 + word($C42F8C + 2*allocationSlot)`,
plus `$100` for an odd chunk count. The connection is explicit: `$C01E38` stores
resource byte 0 at `$467C`, and `$C0201C..$C0202B` applies the odd-count adjustment.
The allocation algorithm deciding which slot is available is separate.

The normal upload entry `$C0A4C4` chooses an inline resource entry using:

```
entryAddress = resourceAddress + 9
             + 4 * word($C0A60B + 2*directionSelector)
             + 2 * (animationPhase != 0)
```

The tested selectors are 0–7 and phase values 0/1. The actual direction table
is read from the user's ROM; no selector bounds check has been established.
The routine loads the chunk count, byte size, and initial destination from the
entity fields, then transfers consecutive source chunks through the placement
wrapper. Entry flags remain in `$341A`, including the definition-variant bit.
The optional leading-chunk fill is controlled by `$2BAA`. At `$C0A501`,
graphics-entry bit 1 bypasses filling. Otherwise `$2BAA` bit 3 enables one
leading fixed-source chunk, and bit 2 enables a second. `$C0A512..A53B`
uses DMA profile 3 and the zero byte at `$C40BE8` (file `$040BE8`). Each
fill consumes one chunk from the count, without advancing the graphics source.
The remaining chunks therefore start at the original graphics-entry address.
If filling consumes the entire count, the routine returns before updating
`$341A`; the prior retained entry survives. The game meaning of these effect
bits and the callers that set them remain open.

`tests/integration_sprite_dma.nim` runs **4,864 full-upload cases** using 19
resources: representatives of every count/size combination plus the previously
examined character resources. Each runs original `$C0A4C4` across eight direction
selectors, two phases, two allocation slots, `$2BAA` values 0/4/8/12, and
queued/immediate transfer modes. Each case resets the emulator's per-frame DMA
budget, since these independent uploads do not represent one enormous frame.
The expected model reads the selected real graphics entry and compares the whole
VRAM array after placing every chunk; it also checks the final destination and
retained entry word. Existing synthetic and short-transfer tests remain.

For resource 437, the normal upload is three 64-byte chunks (192 bytes total).
Direction 0/phase 0 selects source `$D1BAC0`; allocation slot 0 starts at VRAM
word `$4100`. This is a fully sized transfer example, not a rendered-image or
palette-fidelity claim.

The test initializes entity fields from the derived resource formulas. It does
not execute the allocator, the whole spawn sequence, or full interrupt timing.
Screen rendering remains open. Next: combine the allocation clearing verified
below with the baseline
OBJ palette verified below with this upload and the verified definitions to
render a representative sprite faithfully.

### Sprite allocation and clearing

The resource-header reader `$C01DED` derives width in 8-pixel tiles as resource
byte 1 shifted right four, storing it in `$467A`; resource byte 0 supplies
height in `$467C`. The original caller `$C01EA0..1EB2` passes width in A,
height in X, and the owner tag in Y to `$C01C52`.

`$C01C52` rounds both dimensions up to even values and requests
`ceil(width/2) * ceil(height/2)` slots from `$C01B96`. Each slot represents
one 16×16 tile block. The allocator searches 88 occupancy bytes at
`$7E4A00..4A57` for the first contiguous free run, accepting a run ending at
the final slot. It writes `owner.lowByte | $80` to each selected byte and
returns the starting slot, or `$FF03` on exhaustion. Owner values `$7F` and
`$FF` consequently produce the same stored tag. This contract is for positive
dimensions whose rounded allocation fits the pool; oversized and zero-sized
requests are not established as safe inputs.

If either dimension was rounded, `$C01CA2..1D33` clears the **entire allocated
region**, not just padding. If both were already even, it leaves VRAM untouched.
For slot `s`, the top two 8×8 tiles occupy 32 VRAM words starting at
`$4000 + (s div 8)*$200 + (s mod 8)*$20`; the bottom two occupy another
32 words at that address plus `$100`. The mapping comes from `$C42F8C`.
The clearing loop batches adjacent slots up to eight-slot boundaries and sends
two fixed-source DMA requests per batch, using the zero byte at `$C40BE8`.
Allocation failure changes neither occupancy nor VRAM.

`nim r tests/integration_sprite_allocation.nim` verifies 3,072 synthetic cases:
dimensions 1–8, seven occupied-prefix lengths plus a fragmented pool, three
owner tags, and queued/immediate DMA. It checks every occupancy byte, boundary
guards, the returned slot, register-width/D/DBR/stack contract, all VRAM words,
and transfer counts. Another 928 cases execute the original header-reader and
allocation call chain for all 464 resource entries in both DMA modes, including
the real height-10 resources. Calls enter native, decimal-clear with DBR `$7E`
and private direct-page scratch. Full spawning and full interrupt timing are
outside this test.

Resource 437 is 2×3 tiles, so allocation reserves two 16×16 slots and clears
them before its three-row graphics upload. At slot 0, the upload starts at
`$4100`, leaving the unused top row zero. This explains the transparent padding
needed when combining its two sprite elements with the actual graphics.

### Baseline OBJ palette and interrupt upload

The original fragment `$C0B55B..B56E` sets the caller's long source pointer
at direct-page `$0E` to `$C30000` (file `$030000`), requests 256 bytes, and
calls `$C08ED2` with destination `$0300`. With DBR `$7E` and native 16-bit
registers, that helper copies 128 words into WRAM `$7E0300..03FF`. These are
the baseline OBJ colors; this does not establish the active palette in every
scene, which may modify the staging buffer before publication.

`requestCgramDma` at `$C0856B` stores only A's low byte in `$0030`, then
returns with M clear. The interrupt fragment `$C081C8..81F6` reads this byte
as a descriptor offset. Verified requests are:

| Request | Source in bank 0 | Bytes | First CGRAM color |
|---|---|---|---|
| `$00` | No transfer | 0 | — |
| `$08` | `$0200` | 256 | 0 |
| `$10` | `$0300` | 256 | 128 |
| `$18` | `$0200` | 512 | 0 |

Descriptor fields are size at `$C08F92 + request`, source offset at
`$C08F94 + request`, and CGRAM start at `$C08F96 + request`. The fragment
uses DMA channel 0, mode 0, destination `$2122`, resets the CGRAM address
through `$2121`, clears the request byte, and adds the size to `$0099`.
Entry requires M16/X8, D/DBR zero, and decimal mode clear. This is a bounded
interrupt-fragment contract, not a full interrupt timing test.

`nim r tests/integration_sprite_palette.nim` executes the original request
routine and interrupt fragment for 16 synthetic 15-bit palette patterns and
all four requests (64 cases). It checks every CGRAM entry, preservation of
the unselected half, the neighboring byte `$0031`, transfer accounting, and
the next visit skipping the cleared request. A further case executes the
original baseline copy, checks all 256 staging bytes against the user's ROM
and both boundary guards, then uploads them to OBJ CGRAM. No palette bytes
are embedded in the test. Scene overrides and the combination with sprite
rendering remain unverified.
