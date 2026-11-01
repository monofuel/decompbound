; Record readers, APU $0F2D..0F4A / file $260A6F..260A8C (30 bytes).
; CALL/RET, DP zero; YA=record address. Copies seven/three bytes respectively
; into $04D8..DE / $04DA..DC, using wrapping 16-bit indexed reads.
; $20/$21=original pointer; X preserved, A=last byte,Y=count,C=1,N=0/Z=1;
; H/V/P/I/B preserved. Pointer scratch $20/$21 is written before any reads;
; source/destination overlap follows forward store order, not a snapshot copy.
; The record bytes remain user-ROM data, not literals here. See docs/audio.md.
    .org $0F2D
spcRecordInterpreterReadSeven:
    MOVW $20, YA
    MOV Y, #$00
copySeven:
    MOV A, [$20]+Y
    MOV $04D8+Y, A
    INC Y
    CMP Y, #$07
    BNE copySeven
    RET

; $0F3C: same contract, copies three bytes and returns Y=3.
spcRecordInterpreterReadThree:
    MOVW $20, YA
    MOV Y, #$00
copyThree:
    MOV A, [$20]+Y
    MOV $04DA+Y, A
    INC Y
    CMP Y, #$03
    BNE copyThree
    RET
