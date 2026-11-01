; Sample host port, APU $0635..0653 / file $260177..260195 (31 bytes).
; CALL/RET: DP zero, X=port index (real service callers use 3,2,1).
; Save previous $04A4+X in scratch $20; read $00F4+X until one pair agrees.
; Publish stable input to $00+X, echo it to the same port, and save $04A4+X.
; Store/return the byte if changed, otherwise zero, in $04A0+X and A.
; Preserves X/Y/H/V/P/I/B. C/N/Z come from stableByte-oldByte CMP, including
; changed-to-zero inputs; matching pairs are required for termination.
; Native stack balances. No command/SFX identity is inferred. See docs/audio.md.
    .org $0635
spcSampleHostPort:
    MOV A, $04A4+X
    MOV $20, A
readStableHostPort:
    MOV A, $00F4+X
    CMP A, $00F4+X
    BNE readStableHostPort

    MOV $00+X, A
    MOV $00F4+X, A
    MOV $04A4+X, A
    CMP A, $20
    BNE storeChangedInput
    MOV A, #$00            ; Equal input is suppressed; changed zero also returns zero.
storeChangedInput:
    MOV $04A0+X, A
    RET
