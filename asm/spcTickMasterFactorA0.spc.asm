; Tick master-factor countdown, APU $2DD5..2DE9 / file $262917..26292B (21B).
; CALL/RET: DP zero, countdown $043A. Zero stays zero; nonzero decrements.
; On expiry tails through $162E to set master word $58/$59=$A000, preserving
; pending master fade $5A..$5D and dirty mask $5E. No direct DSP writes.
; Preserves X/H/V/P/I/B; C=1. Nonexpiry returns A=count,N/Z from count CMP zero,
; preserving Y; expiry returns A=0,Y=$A0,N=0/Z=1. Native stack balances.
; TODO: identify the broader trigger role of $043A. See docs/audio.md.
    .org $2DD5
spcTickMasterFactorA0:
    MOV A, !$043A
    CMP A, #$00
    BNE decrementMasterCount
returnMasterCount:
    RET

decrementMasterCount:
    DEC A
    MOV !$043A, A
    CMP A, #$00
    BNE returnMasterCount
    MOV A, #$A0
    JMP $162E              ; A-to-Y master-factor adapter and shared RET.
