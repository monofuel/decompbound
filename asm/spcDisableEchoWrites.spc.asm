; Disable echo writes, APU $0B03..$0B09 / file $260645..$26064B (7 bytes).
; CALL/RET: DP zero; stores incoming YA into BOTH current echo-volume words.
; F6 dispatch has no operand and supplies A=Y=0, but direct calls need not.
; Sets FLG shadow $48 bit 5; preserves pending fade $64..$6A and mask $4A.
; Preserves A/X/Y and all PSW bits; no direct DSP write. See docs/audio.md.
    .org $0B03
spcDisableEchoWrites:
    MOVW $60, YA
    MOVW $62, YA
    SET1 $48.5
    RET
