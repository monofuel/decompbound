; Native state clear, APU $15DB..15E3 / file $26111D..261125 (9B).
; CALL/RET: clears slot-one state $04B5 and countdown $0491; returns A=0.
; Preserves X/Y/C/H/V/P/I/B; N=0/Z=1. Preceding three bytes are record metadata.
    .org $15DB
spcClearServiceRecordState:
    MOV A, #$00
    MOV !$04B5, A
    MOV !$0491, A
    RET
