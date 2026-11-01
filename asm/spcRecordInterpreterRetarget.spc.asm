; Retarget port-two record table, APU $1152..116F / file $260C94..260CB1 (30 bytes).
; CALL/RET, DP zero; $20/$21=P. Reads high byte P-2 into $17C6, then low byte
; P-3 into $17C5 while decrementing pointer scratch. Overlap observes this order:
; P=$17C9 reads its newly written high byte again as low. Stores 1 at copied
; input $04B2 and restores P. Reads wrap; neither target nor P is validated.
; Returns A=1,X=0,Y preserved; C/H/V/P/I/B preserved,N/Z from 16-bit P.
; Native stack balances. Prefix data remain in the user's ROM. See docs/audio.md.
    .org $1152
spcRecordInterpreterRetargetPortTwo:
    MOV X, #$00
    DECW $20
    DECW $20
    MOV A, [$20+X]
    MOV !$17C6, A
    DECW $20
    MOV A, [$20+X]
    MOV !$17C5, A
    MOV A, #$01
    MOV !$04B2, A
    INCW $20
    INCW $20
    INCW $20
    RET
