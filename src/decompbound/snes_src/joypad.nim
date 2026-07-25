## Joypad auto-read poll — HVBJOY wait + JOY1/JOY2 latch into DP shadows
## (file 0x008496 / SNES $C08496).
##
## Main joypad sample entry used from the NMI-side path (`JSR $8496` at
## `$C08783`). Waits for the hardware auto-joypad read to finish, then JSR
## the raw register latch and edge-processing helpers. ADOPTED into the
## region registry (adopted.nim); gold-gated by tests/test_regions.nim.

import
  ../snes_asm

const
  PollJoypadsOffset* = 0x008496
  PollJoypadsSnes* = 0xC08496'u32
  ## CPU MMIO: HVBJOY — bit 0 = auto-joypad-read busy.
  HvbjoyReg* = 0x004212'u32
  ## Absolute low-16 of the raw joypad latch helper at `$C0841B` (same bank;
  ## JSR operand is 16-bit). Reads JOY1 (`$4218`) → DP `$77` and JOY2
  ## (`$421A`) → DP `$79` (with an optional demo-playback override).
  ReadJoypadRegsAbs* = 0x841B'u32
  ## Absolute low-16 of the demo-record helper at `$C08456` (same bank).
  ## Not adopted here — only the call site is fixed.
  RecordJoypadDemoAbs* = 0x8456'u32
  ## DP: raw joypad words after the latch helper (pad 1 at `$77`, pad 2 at `$79`).
  ## Indexed as `$77,X` with X in `{0,2}`.
  JoyRawDp* = 0x77'u32
  ## DP: previous-frame held buttons (same X stride).
  JoyPrevDp* = 0x65'u32
  ## DP: newly pressed buttons this frame (`raw & ~prev`).
  JoyNewDp* = 0x6D'u32
  ## DP: auto-repeat / held-with-delay output.
  JoyRepeatDp* = 0x69'u32
  ## DP: repeat countdown timer per pad.
  JoyRepeatTimerDp* = 0x71'u32
  ## DP: masked raw (face/d-pad bits only after `AND #$FFF0`).
  JoyMaskedDp* = 0x75'u32
  ## DP: pad-2 siblings of prev/new/repeat (X=0 uses `$65/$6D/$69`; the ORA
  ## merge path also folds `$67/$6B/$6F` when `$7E436C` is clear).
  JoyPrev2Dp* = 0x67'u32
  JoyRepeat2Dp* = 0x6B'u32
  JoyNew2Dp* = 0x6F'u32
  ## Initial auto-repeat delay (frames) after a new press.
  JoyRepeatDelayInitial* = 0x0014'u32
  ## Repeat period once the initial delay expires.
  JoyRepeatPeriod* = 0x0003'u32
  ## Mask keeping d-pad + face buttons (clears the low nibble signature bits).
  JoyButtonMask* = 0xFFF0'u32
  ## WRAM gate: when nonzero, skip the pad1|pad2 merge into the primary shadows.
  JoyMergeGateWram* = 0x7E436C'u32
  ## Frame counter bumped when any newly-pressed button is nonzero.
  # TODO: pin all readers of `$0A34` before a stronger name in memory-map.md.
  JoyNewPressCounter* = 0x0A34'u32
  StatusM* = 0x20'u32
  StatusMX* = 0x30'u32

proc pollJoypads*(): seq[uint8] =
  ## Wait for auto-joypad ready, latch pads, then compute new/repeat edges.
  ##
  ## Entry (JSR): any M; forces 8-bit A for the HVBJOY poll, then 16-bit A/X
  ## for the per-pad loop. Returns with RTS (not RTL).
  ##
  ## Sequence:
  ## 1. `SEP #$20` / spin on `LDA $4212 / LSR / BCS` until auto-read busy
  ##    clears (HVBJOY bit 0).
  ## 2. `JSR $841B` — raw JOY1/JOY2 → DP `$77`/`$79` (and demo override).
  ## 3. `JSR $8456` — optional demo recorder (not adopted).
  ## 4. For X in `{2,0}` (pad 2 then pad 1): mask raw with `#$FFF0`, compute
  ##    new = raw & ~prev, update prev, and run the auto-repeat timer into
  ##    the repeat DP slot (`$0014` initial delay, `$0003` period).
  ## 5. If `$7E:436C` is zero, OR pad-2 shadows into pad-1 shadows.
  ## 6. If any new press remains, `INC $0A34`.
  ##
  ## Evidence (registers / call graph):
  ## - abs `$4212` HVBJOY — busy wait (bit 0 via LSR/BCS).
  ## - JSR `$841B` reads abs `$4218` JOY1 and `$421A` JOY2 into DP.
  ## - Sole traced caller: `$C08783` (`JSR $8496`) on the NMI-side path that
  ##   also polls HVBJOY before entering this routine's bank-local frame.
  snesAsm(PollJoypadsSnes, NativeFlags16):
    sep StatusM
    label "waitAutoJoy"
    lda abs HvbjoyReg
    lsr a
    bcs "waitAutoJoy"
    jsr abs ReadJoypadRegsAbs
    jsr abs RecordJoypadDemoAbs
    rep StatusMX
    ldx 0x0002
    label "padLoop"
    lda dpx JoyRawDp
    andOp JoyButtonMask
    sta dp JoyMaskedDp
    lda dpx JoyPrevDp
    eor 0xFFFF
    andOp dp JoyMaskedDp
    sta dpx JoyNewDp
    lda dp JoyMaskedDp
    cmp dpx JoyPrevDp
    sta dpx JoyPrevDp
    beq "sameButtons"
    lda dpx JoyNewDp
    sta dpx JoyRepeatDp
    lda JoyRepeatDelayInitial
    sta dpx JoyRepeatTimerDp
    bra "nextPad"
    label "sameButtons"
    ldy dpx JoyRepeatTimerDp
    beq "repeatFire"
    dec dpx JoyRepeatTimerDp
    stz dpx JoyRepeatDp
    bra "nextPad"
    label "repeatFire"
    sta dpx JoyRepeatDp
    lda JoyRepeatPeriod
    sta dpx JoyRepeatTimerDp
    label "nextPad"
    dex
    dex
    bpl "padLoop"
    lda long JoyMergeGateWram
    bne "skipMerge"
    lda dp JoyPrev2Dp
    ora dp JoyPrevDp
    sta dp JoyPrevDp
    lda dp JoyRepeat2Dp
    ora dp JoyRepeatDp
    sta dp JoyRepeatDp
    lda dp JoyNew2Dp
    ora dp JoyNewDp
    sta dp JoyNewDp
    label "skipMerge"
    lda dp JoyNewDp
    beq "done"
    inc abs JoyNewPressCounter
    label "done"
    rts
