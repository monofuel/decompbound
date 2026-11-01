; Clear host-slot state, APU $1438..1452 / file $260F7A..260F94 (27 bytes).
; CALL/RET: zero slot-state bytes $04B4..04B7, then copied/pending bytes
; $04B0..04B3. Other auxiliary countdown and record words remain untouched.
; Returns A=0,N=0/Z=1; preserves X/Y/C/H/V/P/I/B, with one native return.
; DP-independent; no CONTROL/DSP writes. TODO: full slot-zero policy remains
; open; this helper does not interpret command identities. See docs/audio.md.
    .org $1438
spcClearHostCommandState:
    MOV A, #$00
    MOV !$04B4, A
    MOV !$04B5, A
    MOV !$04B6, A
    MOV !$04B7, A
    MOV !$04B0, A
    MOV !$04B1, A
    MOV !$04B2, A
    MOV !$04B3, A
    RET
