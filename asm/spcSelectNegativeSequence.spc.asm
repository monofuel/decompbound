; Negative selection mapping, APU $079A..07A8 / file $2602DC..2602EA (15 bytes).
; From $0772 with DP zero and original selection already stored in $04.
; Map any A byte to X=(2*((A&127)+1)) mod256; $FF wraps to table slot zero.
; Load YA from word table $2F46+X, then JMP shared $0782 to store cursor $40,
; set $0C=2 and queue uninhibited key-off before the caller's RET. This fragment
; preserves SP/P/I/B/H/V; C is bit7 of the incremented index, N/Z from low byte.
    .org $079A
spcSelectNegativeSequence:
    AND A, #$7F
    INC A
    ASL A
    MOV X, A
    MOV A, $2F47+X
    MOV Y, A
    MOV A, $2F46+X
    JMP $0782              ; Shared interior of spcSelectSequence, not a fresh CALL.
