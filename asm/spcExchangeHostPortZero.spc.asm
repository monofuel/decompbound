; Exchange host port zero, APU $0625..0634 / file $260167..260176 (16 bytes).
; CALL/RET: DP zero; publishes sequence selection/activity byte $04 to $00F4.
; Repeatedly reads port zero twice until one pair agrees, then stores that byte
; in $00. Termination requires a matching pair; no command is interpreted here.
; Returns A=$00, C=1/N=0/Z=1 from the final equal CMP; preserves X/Y/H/V/P/I/B.
; Native stack balances; the port write precedes every input read. See docs/audio.md.
    .org $0625
spcExchangeHostPortZero:
    MOV A, $04
    MOV !$00F4, A
readStablePortZero:
    MOV A, !$00F4
    CMP A, !$00F4
    BNE readStablePortZero
    MOV $00, A
    RET
