## Wait for APU port 0 idle, then invalidate the current-song cache
## (file 0x00ABC6 / SNES $C0ABC6) plus its port-0 poll helper
## (file 0x00AC20 / SNES $C0AC20).
##
## Called by loadSong ($C4FBBD) after writeApuPort1Toggled when stopping the
## resident driver before a package re-upload (see song_loader.nim
## WaitApuIdleClearSong). ADOPTED mid-region after queueApuCommand /
## writeApuPort* siblings; gold-gated by tests/test_regions.nim.

import
  ../snes_asm

const
  WaitApuIdleClearSongOffset* = 0x00ABC6
  WaitApuIdleClearSongSnes* = 0xC0ABC6'u32
  ReadApuPort0Offset* = 0x00AC20
  ReadApuPort0Snes* = 0xC0AC20'u32
  ## APU communication port 0 (S-CPU side). Written 0 to request idle; polled
  ## until the low byte reads back 0 before the song cache is cleared.
  ApuPort0* = 0x002140'u32
  ## WRAM: last song ID loaded by loadSong. Forced to $FFFF so the next load
  ## never early-outs on "same song" after a stop-music handshake.
  CurrentSongId* = 0xB53B'u32
  ## Sentinel written to CurrentSongId after port 0 goes idle.
  SongCacheInvalid* = 0xFFFF'u32
  ByteMask* = 0x00FF'u32
  StatusM* = 0x20'u32
  StatusMX* = 0x30'u32

proc readApuPort0*(): seq[uint8] =
  ## Read APU port 0 ($2140) and return its low byte zero-extended in A.
  ##
  ## Literally `SEP #$20 / LDA long $2140 / REP #$30 / AND #$00FF / RTL`.
  ## Sole in-ROM caller in the adopted audio spine is waitApuIdleClearSong
  ## (poll until A == 0). Named for the verified port read, not a higher-level
  ## driver state.
  snesAsm(ReadApuPort0Snes, NativeFlags16):
    sep StatusM
    lda long ApuPort0
    rep StatusMX
    andOp ByteMask
    rtl

proc waitApuIdleClearSong*(): seq[uint8] =
  ## Force APU port 0 to 0, spin until it reads idle, clear current-song cache.
  ##
  ## Entry (JSL): any M/X; manages widths itself. Writes #$00 to $2140 (8-bit),
  ## then loops `JSL readApuPort0` + `CMP #$0000` until the port low byte is 0.
  ## Finally stores #$FFFF at $B53B (CurrentSongId) and RTL.
  ##
  ## Evidence:
  ## - Disasm region 0x00ABC6-0x00ABDF (26 bytes) ends at RTL.
  ## - song_loader stop-music path: writeApuPort1Toggled then JSL $C0ABC6.
  ## - $B53B is the same WRAM word loadSong compares/stores as CurrentSongId;
  ##   $FFFF makes the next loadSong treat "no current song" and re-upload.
  ## - Inner JSL $C0AC20 is readApuPort0 (port-0 poll helper adopted below).
  snesAsm(WaitApuIdleClearSongSnes, NativeFlags16):
    sep StatusM
    lda 0x0
    sta long ApuPort0
    rep StatusMX
    label "waitIdle"
    jsl long ReadApuPort0Snes
    cmp 0x0
    bne "waitIdle"
    lda SongCacheInvalid
    sta abs CurrentSongId
    rtl
