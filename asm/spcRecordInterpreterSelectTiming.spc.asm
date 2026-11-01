; Timing selector, APU $0F8F..0FB6 / file $260AD1..260AF8 (40 bytes).
; CALL/RET, DP zero; $22=selector. $0FA1 handles raw byte selectors; $0F8F
; is its special $7F tail, ORing $04D7 into pending key-off $46 and storing
; timing pair 4/2 in $04D8/$04D9. Special return A=2,Y unchanged,N=0/Z=0;
; C is preserved at direct $0F8F entry, set by $0FA1's equality comparison.
; Otherwise index=(selector-1)&255; pair comes from $1068+index and
; $1068+((index+1)&255). No table bounds check; zero wraps between code/data.
; Normal return Y=(index+1)&255,A=second byte,C=(selector>=127),N/Z from A;
; X and H/V/P/I/B
; preserved. Runtime timing bytes are not reproduced here. See docs/audio.md.
    .org $0F8F
spcRecordInterpreterSelectKeyOffTiming:
    MOV A, $46
    OR A, !$04D7
    MOV $46, A
    MOV A, #$04
    MOV !$04D8, A
    MOV A, #$02
    MOV !$04D9, A
    RET
spcRecordInterpreterSelectTiming:
    MOV A, $22
    CMP A, #$7F
    BEQ spcRecordInterpreterSelectKeyOffTiming
    DEC A
    MOV Y, A
    MOV A, $1068+Y
    MOV !$04D8, A
    INC Y
    MOV A, $1068+Y
    MOV !$04D9, A
    RET
