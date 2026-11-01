; Selection prelude, APU $075E..0771 / file $2602A0..2602B3 (20 bytes).
; Shared entry with caller's native frame; DP zero for the following selector.
; Writes hardware KOFF=$FF unconditionally through $0749, then calls three
; external helpers whose broader state effects remain open. This is not just
; queued key-off. After returning helpers, A=0 is stored in $08 and falls into
; $0772, which selects zero using the same caller frame. No blanket preservation
; contract is inferred for X/Y/flags or helper-written RAM/ports.
    .org $075E
spcPrepareSequenceSelection:
    MOV A, #$FF
    MOV Y, #$5C
    CALL $0749             ; Unconditional DSP writer, independent of $1A/$1B.
    CALL $141A             ; External selection/reset helpers; effects not adopted here.
    CALL $1453
    CALL $0EE1
    MOV A, #$00
    MOV $08, A
    ; Fall through $0772: spcSelectSequence with A=0.
