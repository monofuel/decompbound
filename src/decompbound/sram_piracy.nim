## SRAM mirror anti-piracy check (file 0x00A11C / SNES $C0A11C).
## First Goal 1.5 adoption: curated names and constants, same assembler as
## generated regions. See docs/goal-1.5.md.

import
  ./snes_asm

const
  SramPiracyCheckOffset* = 0x00A11C
  SramPiracyCheckSnes* = 0xC0A11C'u32
  ## HiROM cart window: banks $20-$3F / $A0-$BF, $6000-$7FFF → 8KB battery
  ## SRAM. $30:7FF0 and $31:7FF0 both map to the same physical byte on an
  ## 8KB cart; oversized copier SRAM keeps them separate.
  SramProbeA* = 0x307FF0'u32
  SramProbeB* = 0x317FF0'u32
  ## Distinct probe values written to A then B (INC A makes B = A+1).
  SramProbePattern* = 0x30'u32
  ## PPU status register STAT78. Mask is bit 4; full meaning still open.
  Stat78Addr* = 0x00213F'u32
  # TODO: confirm what STAT78 bit 4 gates here (PPU2 version nibble vs field).
  Stat78GateMask* = 0x10'u32
  ## Bytes subtracted from S after PLA before installing a new direct page.
  CallerFrameDelta* = 0x100'u32
  ## Long jump when SRAM mirrors do not collide (copier / bad cart path).
  PiracyLectureAddr* = 0xC30100'u32
  ## Long jump when the cart passes the mirror test and STAT78 gate is set.
  BootContinueAddr* = 0xC30142'u32
  StatusM* = 0x20'u32

proc sramMirrorPiracyCheck*(): seq[uint8] =
  ## Copier detection via SRAM bank mirrors.
  ##
  ## Writes distinct bytes to $30:7FF0 and $31:7FF0. On real 8KB cart SRAM
  ## those addresses alias, so CMP sees equal values and the routine continues.
  ## Oversized copier SRAM keeps the banks separate; the mismatch path long-
  ## jumps to the crime-lecture screen at $C30100.
  ##
  ## On success, samples STAT78 ($213F), gates on bit 4, then either RTL or
  ## restores a caller direct-page frame and long-jumps to $C30142.
  ##
  ## Entry: native mode, 16-bit A/X (M/X clear). Clobbers A; uses long stores.
  ## Called via JSL (see $C0B9A8).
  snesAsm(SramPiracyCheckSnes, NativeFlags16):
    sep StatusM
    lda SramProbePattern
    sta long SramProbeA
    inc a
    sta long SramProbeB
    cmp long SramProbeA
    beq "sramMirrorsOk"
    # Mirrors did not collide: treat as copier / oversized SRAM.
    rep StatusM
    pla
    tsc
    sbc CallerFrameDelta
    tcd
    jml long PiracyLectureAddr
    label "sramMirrorsOk"
    # Branch target still has 8-bit A from the entry SEP; linear flag tracking
    # would inherit the fall-through path's REP, so re-assert m8 here.
    flagHint true, false
    lda long Stat78Addr
    andOp Stat78GateMask
    beq "returnNative"
    rep StatusM
    pla
    tsc
    sbc CallerFrameDelta
    tcd
    jml long BootContinueAddr
    label "returnNative"
    rep StatusM
    rtl
