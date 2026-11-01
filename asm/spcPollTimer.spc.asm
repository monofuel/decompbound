; Timer-zero poll, APU $0579..058B / file $2600BB..2600CD (19 bytes).
; Resident-loop entry, DP zero and writable native stack. Polls $00FD until
; nonzero; actual timer counts are four bits, while arithmetic accepts a byte.
; Pushes that count for spcAdvancePhase $05CD. Adds low(count*32) to $43;
; Y=high(count*32), A=new $43, X preserved, SP decremented modulo 256.
; N/Z/C/H/V from ADC, P/I/B preserved. Carry jumps to service $0596;
; no carry branches directly to $05CD. Neither route checks reset byte $04B1.
    .org $0579
spcPollTimer:
pollTimerZero:
    MOV Y, !$00FD         ; Hardware read clears timer zero's pending count.
    BEQ pollTimerZero
    PUSH Y
    MOV A, #$20
    MUL YA
    CLRC
    ADC A, $43            ; Only the low product participates in routing carry.
    MOV $43, A
    BCC $05CD             ; spcAdvancePhase consumes the saved timer byte.
    JMP $0596             ; spcRunServicePass; skip alternate reset-check entry.
