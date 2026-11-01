; Raw record pitch, APU $10E7..10FB / file $260C29..260C3D (21 bytes).
; CALL/RET, DP zero,YA=raw position,$04DF=even voice offset0..14,$04D6=mask.
; Saves original X on native stack, masks $47 by $04D6, then sets channel X
; from $04DF and calls raw converter $06D4 using YA in $10/$11. Restores X
; independently of $44. Conversion/scaling may write guarded pitch DSP ports;
; Y/A/flags and $10..$17 follow those helpers. No compensated-event correction.
; See docs/audio.md for converter law, authored-curve gates and raw domains.
    .org $10E7
spcRecordInterpreterWritePitch:
    PUSH X
    PUSH A
    MOV A, $47
    AND A, !$04D6
    MOV $47, A
    MOV A, !$04DF
    MOV X, A
    POP A
    MOVW $10, YA
    CALL $06D4
    POP X
    RET
