; Scale signed preview step, APU $0E2B..$0E48 / file $26096D..$26098A.
; CALL/RET: DP zero, word $0E/$0F zero for spcNegateStep, YA=signed step.
; DP $51 is the unsigned phase fraction.
; Adds sign(step)*floor(abs(step)*phase/256) to word $10/$11 modulo 65536.
; Returns resulting coordinate in YA and $10/$11; marks DP $13 bit 7.
; Preserves X; clobbers A/Y/PSW and DP $12/$14/$15. DP $12 holds the original
; step high byte for the conditional-negation helper. See docs/audio.md.
    .org $0E2B
spcScaleSignedStep:
    SET1 $13.7             ; Request output of the preview being calculated.
    MOV $12, Y
    CALL $0BD9             ; spcNegateStep uses zero $0E/$0F for negative YA.

    ; Scale magnitude low byte, retaining only its high product byte.
    PUSH Y                 ; Preserve magnitude high byte across the first MUL.
    MOV Y, $51
    MUL YA
    MOV $14, Y
    MOV $15, #$00

    ; High-byte product plus that retained byte gives floor(magnitude*phase/256).
    MOV Y, $51
    POP A
    MUL YA
    ADDW YA, $14
    CALL $0BD9             ; spcNegateStep restores sign using the saved bit.
    ADDW YA, $10
    MOVW $10, YA
    RET
