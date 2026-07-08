# Ticket: Giygas "red snow" static is the wrong animation phase

Status: FIXED (2026-07-08) — Mode 7 multiply was missing
Filed: 2026-07-04

## Symptom

There is ONE Giygas death animation that runs **Giygas swirl -> random
red/black/white TV snow**. The full progression is shown at the END of the
game. The INTRO deliberately shows **only the snow segment** (the tail of that
animation) and never the swirl — because the game is hiding that the snow IS
Giygas until the very end. "The beginning is secretly the ending" is the
central trick.

Our bug: in the intro `make play` rendered a **coherent Giygas swirl tilemap**
instead of **HDMA-warped TV snow**. Spoiled the reveal.

## Root cause (confirmed)

**Not** wrong tile-frame selection. VRAM is constant for the whole static
window (swirl tiles stay put). The snow look is produced by:

1. BG1 = war card (main), BG2 = Giygas pattern (subscreen)
2. Color math (`CGADSUB=03`, `CGWSEL=02`)
3. Palette thrash (`$C426ED` ramps `$7F0x00` → `$0200` → CGRAM DMA)
4. **Per-scanline BG2HOFS HDMA** (ch5, indirect, table at `$7E3C32`) filling
   a sine-wave offset buffer at `$7E3C46`

The buffer is filled by `$C0AE5A` (`code_00AE4C`), which uses the **Mode 7
general-purpose multiply**:

- Write M7A `$211B` (16-bit write-twice) = amplitude
- Write M7B `$211C` (triggers) with a sine-table byte
- Read MPYM `$2135` (+ MPYH) = `(int16)M7A * (int8)last_M7B_byte` mid/high

**We never implemented `$211B`/`$211C` → `$2134`–`$2136`.** MPY always read 0,
so every HDMA scroll entry was 0, BG2 never warped, and the swirl stayed a
readable tiled face.

## Fix

### 1. Mode 7 multiply (`snesbus.nim`)

- M7A/M7B write-twice latch (`m7MulLatch`)
- On every M7B write: `mpy = (int16)m7a * (int8)value` (24-bit)
- MPYL/M/H readable at `$2134`/`$2135`/`$2136`

### 2. Color math accuracy (`ppu.nim`) — yellow/green linger

F12 savestate at "should be almost faded" had full-bright mid-gray thrash
plus wrong transparent-sub math:

- **Subscreen transparent pixels** must use **COLDATA fixed color** as the
  math operand, not CGRAM `$00`. We used `cgram[0]` (`$32AD` thrash purple),
  so every hole in the noise layer added junk and blew out to yellow/green.
- Color math is now done in the **5-bit** channel domain (hardware), then
  expanded to 8-bit display.

### 3. Timing regs

- `INIDISP` brightness: level 0 = true black (`n/15` for 1..15)
- HVBJOY/RDNMI: scanline-based vblank + sticky NMI flag (not a shared toggle)

Also corrected inverted CGWSEL bit-1 handling in `renderFrame`.

## Verification

- HDMA buffer `$7E3C46` after fix: non-zero sine words (`1E 00`, `B6 FF`, …)
- Mid-scanline BG2HOFS advances (`001E`, `03B6`, `006A`, …)
- Frames ~1300–1600: war card under **churning red static**, not a face grid
- Clean title card after color math drops (~frame 1650 at InstrPerLine=150)

Probe tools (gitignored output under `bin/red_snow/`):

- `src/tools/red_snow_probe.nim` — play-timing frame pack
- `src/tools/hdma_data_dump.nim` / `hdma_static_probe.nim` — table + scroll

## Definition of done

- [x] In `make play`, the intro static reads as churning red snow / warped
      noise, not a coherent Giygas face tile grid, then fades to the clean
      title card.
- [ ] Human eyeball on `make play` (please confirm).
- No regression: title card (post-fade) and world frames unchanged; gold tests
  still green where the ROM is present.
