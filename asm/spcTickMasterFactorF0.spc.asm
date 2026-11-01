; Tick master-factor countdown, APU $2DF3..2E07 / file $262935..262949 (21B).
; CALL/RET: DP zero, countdown $0439. Zero stays zero; nonzero decrements.
; On expiry tails through $162E to set master word $58/$59=$F000, preserving
; pending master fade $5A..$5D and dirty mask $5E. No direct DSP writes.
; Preserves X/H/V/P/I/B; C=1. Nonexpiry returns A=count,N/Z from count CMP zero,
; preserving Y; expiry returns A=0,Y=$F0,N=0/Z=1. Native stack balances.
; TODO: identify the broader trigger role of $0439. See docs/audio.md.
    .org $2DF3
spcTickMasterFactorF0:
    MOV A, !$0439
    CMP A, #$00
    BNE decrementMasterCount
returnMasterCount:
    RET

decrementMasterCount:
    DEC A
    MOV !$0439, A
    CMP A, #$00
    BNE returnMasterCount
    MOV A, #$F0
    JMP $162E              ; A-to-Y master-factor adapter and shared RET.
