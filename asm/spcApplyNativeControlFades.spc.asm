; Native five-channel fade setup, APU $2D37..2D7E / file $262879..2628C0 (72B).
; CALL/shared entry: DP zero, trusted $22/$23 points to five full-byte targets.
; For channel offsets 2,4,6,8,10 set duration 20 and signed 8.8 step from target
; minus current integer, via original $166E. Current words/dirty state and
; other channels stay unchanged. Nominal target rows are disjoint from scratch
; and channel fields; aliased reads observe earlier helper writes. No stream
; fetch or hardware write occurs; absolute cadence is not established here.
; Negative division requires zero $0E/$0F. $166E sets saved $44 for each channel.
; Returns X=10,Y=4,A=last step high; $44=10,$20=last target,$21 unchanged.
; $12 rotates five times; $14/$15 hold the last negative quotient magnitude.
; P/I/B preserved; remaining flags follow final transition helper. Stack balances.
    .org $2D37
spcApplyNativeControlFades:
    MOV Y, #$00
    MOV X, #$02
    MOV A, [$22]+Y
    MOV $20, A
    MOV A, #$14
    PUSH Y
    CALL $166E             ; Stream-free channel-volume transition; refreshes $44.
    POP Y
    INC Y
    MOV X, #$04
    MOV A, [$22]+Y
    MOV $20, A
    MOV A, #$14
    PUSH Y
    CALL $166E
    POP Y
    INC Y
    MOV X, #$06
    MOV A, [$22]+Y
    MOV $20, A
    MOV A, #$14
    PUSH Y
    CALL $166E
    POP Y
    INC Y
    MOV X, #$08
    MOV A, [$22]+Y
    MOV $20, A
    MOV A, #$14
    PUSH Y
    CALL $166E
    POP Y
    INC Y
    MOV X, #$0A
    MOV A, [$22]+Y
    MOV $20, A
    MOV A, #$14
    PUSH Y
    CALL $166E
    POP Y
    RET
