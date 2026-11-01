; NMI brightness fragment, file $0081F7..008225 / SNES $C081F7..C08225 (47B).
; Fall-through only: inherited native interrupt frame; no JSL/RTS/RTL entry.
; The system stack must be disjoint from the low-WRAM shadow fields.
; Original $C08170 setup supplies DP=DBR=0, M16/X8; hardware NMI clears decimal.
; Uses byte delta $28, reload $29, countdown $2A and INIDISP shadow $0D.
; Preserves DP/DBR/stack and X/Y values, leaves M8/X16; A low=shadow, B preserved.
; Clobbers N/Z; C/V change only on an update (C also by saturation CMP).
; Writes $2100 every visit, then falls into $C08226's other PPU-shadow writes.
; This fragment alone establishes neither complete NMI behavior nor scene timing.
    .a16
    .i8
advanceDisplayBrightness:
    SEP #$20
    .a8
    LDA $28
    BEQ writeDisplayBrightness
    DEC $2A
    BPL writeDisplayBrightness

    ; Expiry uses the sign of the decremented byte, not simply count==0.
    LDA $29
    STA $2A
    LDA $0D
    AND #$0F
    CLC
    ADC $28                ; Binary byte arithmetic; large raw deltas can wrap.
    BPL checkBrightLimit
    STZ $001F              ; Dark endpoint also clears pending HDMA enable.
    LDA #$80               ; Force blank, brightness zero.
    BRA finishBrightnessTransition

checkBrightLimit:
    CMP #$10
    BCC storeDisplayBrightness
    LDA #$0F
finishBrightnessTransition:
    STZ $28
storeDisplayBrightness:
    STA $0D

writeDisplayBrightness:
    REP #$10
    .i16
    LDA $0D
    STA $2100
    ; Fall through into the original mosaic/register-shadow service at $C08226.
