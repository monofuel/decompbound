; Reset channel defaults and branch tails, APU $07A9..07E9 (65 bytes),
; file $2602EB..26032B. Callable reset entry requires DP zero and caller frame.
; Visit X=14..0 with descending one-hot $47; real $09B8 sets pan integer/control
; to10 and fraction0. Set channel-volume integer $0301+X=$FF; zero instrument,
; event fraction, pitch offset/pending duration, event guard and modulation depths.
; Global fade counts $5A/$68/$54, pitch offset $50, loop counter $42 and remap
; base $5F become0; master integer $59=$C0, tempo integer $53=$20. Their fractions
; and unlisted fields remain intact. Returns A=0,X=$FE,Y preserved,$47=0;
; C=1/N=0/Z=1, H/V/P/I/B preserved. Shared tails below consume no extra frame.
    .org $07A9
spcResetSequenceChannels:
    MOV X, #$0E
    MOV $47, #$80
nextResetChannel:
    MOV A, #$FF
    MOV $0301+X, A
    MOV A, #$0A
    CALL $09B8             ; spcSetPan returns A=0, preserving X/Y.
    MOV $0211+X, A
    MOV $0381+X, A
    MOV $02F0+X, A
    MOV $0280+X, A
    MOV $0400+X, A
    MOV $B1+X, A
    MOV $C1+X, A
    DEC X
    DEC X
    LSR $47
    BNE nextResetChannel

    MOV $5A, A
    MOV $68, A
    MOV $54, A
    MOV $50, A
    MOV $42, A
    MOV $5F, A
    MOV $59, #$C0
    MOV $53, #$20
    RET

spcPrepareZeroSelectionTail:
    JMP $075E              ; Shared selection prelude with the existing caller frame.
spcSelectSequenceTail:
    JMP $0772              ; Generic A-input selector, not necessarily selection zero.
