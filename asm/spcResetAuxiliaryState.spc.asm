; Reset auxiliary state, APU $141A..1437 / file $260F5C..260F79 (30 bytes).
; CALL/RET: clear host-slot bytes through $1438, then clear countdown $0491,
; override countdowns $0438..043A and four bytes $04C8..04CB.
; Returns A=0,N=0/Z=1; preserves X/Y/C/H/V/P/I/B, and balances native calls.
; DP-independent; no port writes. Unlike this full reset, $1609 expiry calls
; $1438 alone before releasing voices, leaving these extra eight bytes intact.
; TODO: identify the complete role of $04C8..04CB. See docs/audio.md.
    .org $141A
spcResetAuxiliaryState:
    CALL $1438             ; spcClearHostCommandState: clear both four-byte slot arrays.
    MOV A, #$00
    MOV !$0491, A
    MOV !$0438, A
    MOV !$0439, A
    MOV !$043A, A
    MOV !$04C8, A
    MOV !$04C9, A
    MOV !$04CA, A
    MOV !$04CB, A
    RET
