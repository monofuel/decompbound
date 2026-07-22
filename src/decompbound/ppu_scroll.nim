## PPU scroll-offset flusher — BG3VOFS ($2112)
## (file 0x00AD9F / SNES $C0AD9F).
##
## Small RTS-bounded helper that push-writes the BG3 vertical scroll register
## from its WRAM shadow pair. ADOPTED into the region registry (adopted.nim);
## gold-gated by tests/test_regions.nim.

import
  ./snes_asm

const
  FlushBg3VofsOffset* = 0x00AD9F
  FlushBg3VofsSnes* = 0xC0AD9F'u32
  ## PPU: BG3VOFS — background 3 vertical offset (write-twice, low then high).
  Bg3VofsReg* = 0x002112'u32
  ## WRAM shadow of BG3 vertical scroll (low byte at $003B, high at $003C).
  ## Same word the BG layer setup family clears via Bg3ScrollV ($003B).
  Bg3ScrollVLo* = 0x003B'u32
  Bg3ScrollVHi* = 0x003C'u32
  StatusM* = 0x20'u32

proc flushBg3Vofs*(): seq[uint8] =
  ## Flush BG3 vertical scroll shadow `$003B`/`$003C` to BG3VOFS (`$2112`).
  ##
  ## Entry (JSR): any M; forces 8-bit A for the write-twice sequence, then
  ## restores 16-bit A before RTS. Each BG scroll register is write-twice on
  ## the SNES (low byte then high byte into the same MMIO address).
  ##
  ## Evidence: `LDA $003B / STA long $2112 / LDA $003C / STA long $2112`.
  ## Sole traced caller: `$C0F8BD` (`JSR $AD9F`) after `STA $003B` of a new
  ## vertical offset. Sibling of the NMI path that flushes all four layers
  ## from `$41..$60`, but this is the only standalone RTS-bounded BG3VOFS
  ## flusher in bank `$C0`.
  snesAsm(FlushBg3VofsSnes, NativeFlags16):
    sep StatusM
    lda abs Bg3ScrollVLo
    sta long Bg3VofsReg
    lda abs Bg3ScrollVHi
    sta long Bg3VofsReg
    rep StatusM
    rts
