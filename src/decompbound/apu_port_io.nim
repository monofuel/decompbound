## Small APU port I/O helpers next to the upload streamer
## (file 0x00ABBD+ / SNES $C0ABBD+).
##
## docs/audio.md: "SFX are fire-and-forget port pokes to the resident driver."
## These three are RTL-bounded, byte-short, and named only for the port action
## each byte stream verifiably performs. ADOPTED mid-region after uploadApuPackages
## (adopted.nim); gold-gated by tests/test_regions.nim.

import
  ./snes_asm

const
  WriteApuPort0Offset* = 0x00ABBD
  WriteApuPort0Snes* = 0xC0ABBD'u32
  WriteApuPort3Cmd57Offset* = 0x00AC01
  WriteApuPort3Cmd57Snes* = 0xC0AC01'u32
  WriteApuPort1ToggleOffset* = 0x00AC0C
  WriteApuPort1ToggleSnes* = 0xC0AC0C'u32
  ApuPort0* = 0x002140'u32
  ApuPort1* = 0x002141'u32
  ApuPort3* = 0x002143'u32
  ## Phase / handshake latch OR'd into the byte written to $2141; bit 7 is
  ## toggled after each poke so successive commands alternate the high bit.
  ApuPort1PhaseLatch* = 0x1ACB'u32
  PhaseToggleBit* = 0x80'u32
  ## Opaque command byte written to $2143 by the song-loader warm path.
  # TODO: identify what the resident driver does with $57 on port 3.
  ApuPort3Command57* = 0x57'u32
  StatusM* = 0x20'u32
  StatusMX* = 0x30'u32

proc writeApuPort0*(): seq[uint8] =
  ## Write A (8-bit) to APU port 0 ($2140) and return.
  ##
  ## Literally `SEP #$20 / STA long $2140 / REP #$30 / RTL`. Call site in the
  ## song loader at $C4FD12 (after package upload). Fire-and-forget port poke.
  snesAsm(WriteApuPort0Snes, NativeFlags16):
    sep StatusM
    sta long ApuPort0
    rep StatusMX
    rtl

proc writeApuPort3Cmd57*(): seq[uint8] =
  ## Write command byte $57 to APU port 3 ($2143) and return.
  ##
  ## Song loader $C4FBBD calls this when $B4B6 is zero (warm path before a
  ## music change). The port write is certain; the meaning of $57 inside the
  ## resident SPC driver is still open (see TODO on ApuPort3Command57).
  snesAsm(WriteApuPort3Cmd57Snes, NativeFlags16):
    sep StatusM
    lda ApuPort3Command57
    sta long ApuPort3
    rep StatusMX
    rtl

proc writeApuPort1Toggled*(): seq[uint8] =
  ## Write `(A | $1ACB)` to APU port 1 ($2141), then toggle bit 7 of $1ACB.
  ##
  ## Entry: A holds the low command bits; $1ACB supplies the alternating phase
  ## bit used by dual-phase APU handshakes. Song loader uses this (e.g. JSL at
  ## $C4FBEC with A = 1) before stopping/re-uploading music. Named for the
  ## verified port + toggle, not a higher-level SFX id.
  snesAsm(WriteApuPort1ToggleSnes, NativeFlags16):
    sep StatusM
    ora abs ApuPort1PhaseLatch
    sta long ApuPort1
    lda PhaseToggleBit
    eor abs ApuPort1PhaseLatch
    sta abs ApuPort1PhaseLatch
    rep StatusMX
    rtl
