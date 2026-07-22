## Queue an APU command byte into the 8-slot ring buffer
## (file 0x00ABE0 / SNES $C0ABE0).
##
## docs/audio.md lists $C0ABE0 among the SFX / fire-and-forget helpers next to
## the port pokes at $C0ABBD / $C0AC01 / $C0AC0C. This one does not touch
## $2140-$2143 itself: it enqueues `(A | $1ACA)` into WRAM `$1AC2,X` with
## write index `$00CA` (mod 8) and toggles phase bit 7 of `$1ACA`. Named for
## the verified queue, not a higher-level SFX id. ADOPTED mid-region after
## wait-idle ($C0ABC6); gold-gated by tests/test_regions.nim.

import
  ./snes_asm

const
  QueueApuCmdOffset* = 0x00ABE0
  QueueApuCmdSnes* = 0xC0ABE0'u32
  ## Circular write index into the command queue (mod 8).
  ApuCmdQueueIndex* = 0x00CA'u32
  ## Phase / handshake latch OR'd into each queued byte; bit 7 toggled after
  ## each non-zero enqueue (same pattern as $1ACB on writeApuPort1Toggled).
  ApuCmdPhaseLatch* = 0x1ACA'u32
  ## Eight-byte command queue base; STA abs,X with X = $00CA.
  ApuCmdQueueBase* = 0x1AC2'u32
  QueueIndexMask* = 0x07'u32
  PhaseToggleBit* = 0x80'u32
  ## Relative offset of BEQ when A == 0: lands on writeApuPort3Cmd57 ($C0AC01).
  ## Zero argument means "issue port-3 $57" instead of enqueueing.
  BranchToPort3Cmd57* = 0x1B'u32
  StatusMX* = 0x30'u32

proc queueApuCommand*(): seq[uint8] =
  ## Enqueue A into the APU command ring buffer, or issue port-3 $57 if A is 0.
  ##
  ## Entry (JSL): any flags; forces 8-bit A/X. If A == 0, BEQ +$1B into the
  ## already-adopted writeApuPort3Cmd57 at $C0AC01 (poke $57 → $2143). If A is
  ## non-zero: X = `$00CA`, store `(A | $1ACA)` at `$1AC2,X`, advance the index
  ## mod 8, toggle bit 7 of `$1ACA`, restore 16-bit A/X, RTL.
  ##
  ## Evidence: disasm byte stream; docs/audio.md helper list; many call sites
  ## pass a non-zero command then JSL $C0ABE0. Does not claim the bytes are a
  ## particular SFX id — only the queue + phase behavior is proven.
  snesAsm(QueueApuCmdSnes, NativeFlags16):
    sep StatusMX
    cmp 0x0
    beq BranchToPort3Cmd57
    ldx abs ApuCmdQueueIndex
    ora abs ApuCmdPhaseLatch
    sta absx ApuCmdQueueBase
    txa
    inc a
    andOp QueueIndexMask
    sta abs ApuCmdQueueIndex
    lda PhaseToggleBit
    eor abs ApuCmdPhaseLatch
    sta abs ApuCmdPhaseLatch
    rep StatusMX
    rtl
