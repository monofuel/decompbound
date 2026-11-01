; Apply command E1, APU $09B8..$09D5 / file $2604FA..$260517.
; Dispatcher/RET: direct page zero; X is even channel offset 0..14.
; A is the operand already fetched by dispatch; no further bytes are read.
; $0431 nonzero replaces the effective value with decimal 10. Stores full
; control at $0351+X and five-bit integer position at $0331+X; clears fraction.
; Preserves X/Y and original operand in DP $20; returns A=0, C=1, N=0, Z=1.
; Makes no DSP writes; other PSW bits are preserved.
; See docs/audio.md for the position and phase consumers.
    .org $09B8
spcSetPan:
    MOV $20, A
    MOV A, $0431
    CMP A, #$00
    BEQ useOperand
    MOV A, #$0A
    JMP storeControl
useOperand:
    MOV A, $20
storeControl:
    MOV $0351+X, A         ; Bits 7/6 independently invert left/right phase.
    AND A, #$1F
    MOV $0331+X, A         ; Integer coordinate; values 21..31 are not clamped.
    MOV A, #$00
    MOV $0330+X, A         ; Fractional coordinate.
    RET
