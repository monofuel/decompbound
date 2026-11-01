; Scale pitch, APU $070E..$0732 / file $260250..$260274.
; CALL/shared tail: direct page zero; X is even channel offset 0..14.
; Input pitch is DP $14/$15; unsigned 8.8 multiplier is $0220+X/$0221+X.
; Produces DP $16/$17 = ((pitch*multiplier)>>8) modulo 65536; no clamp.
; Preserves X; clobbers A/Y/PSW. Falls into spcWritePitch at $0733, whose
; final guarded DSP write returns to the caller. See docs/audio.md.
    .org $070E
spcPitchScale:
    ; Accumulate products after discarding the low-low product's low byte.
    MOV A, $0220+X
    MOV Y, $15
    MUL YA
    MOVW $16, YA
    MOV A, $0220+X
    MOV Y, $14
    MUL YA
    PUSH Y
    MOV A, $0221+X
    MOV Y, $14
    MUL YA
    ADDW YA, $16
    MOVW $16, YA

    ; The high-high product contributes only its low byte after scaling.
    MOV A, $0221+X
    MOV Y, $15
    MUL YA
    MOV Y, A
    POP A                  ; High byte of the earlier low-low product.
    ADDW YA, $16
    MOVW $16, YA
    ; Fall through to spcWritePitch at APU $0733.
