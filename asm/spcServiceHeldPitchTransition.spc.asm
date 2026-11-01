; Service an F9 following a held channel, APU $0B84..$0B93 (16 bytes).
; File $2606C6..$2606D5. CALL-style entry: DP zero, X=even channel offset.
; Nonzero active count $A0+X returns via shared RET $0BBB without reading the
; stream. Otherwise peek [$30+X]; non-F9 also returns without consuming it.
; Skip paths preserve X/Y and state; A/count sets N/Z, or CMP F9 sets N/Z/C.
; Matching F9 skips its opcode, fetches delay, then falls into $0B94 to consume
; duration/target and initialize active state. That path requires $44=X and
; zero word $0E/$0F for signed division; A/Y/flags and scratch are clobbered.
; No local port writes. Actual held caller is $08ED. See docs/audio.md.
    .org $0B84
spcServiceHeldPitchTransition:
    MOV A, $A0+X
    BNE $0BBB              ; Existing active transition suppresses even the peek.
    MOV A, [$30+X]
    CMP A, #$F9
    BNE $0BBB              ; Leave other tokens for the normal event consumer.
    CALL $0957             ; Advancing-fetch interior: skip opcode without rereading it.
    CALL $0955             ; Fetch first operand into A/Y, ready for the shared tail.
    ; Fall through to spcStartActivePitchTransition at $0B94.
