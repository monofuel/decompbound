; Signed step division, APU $0BC7..0BE2 / file $260709..260724 (28 bytes).
; CALL/RET: direct page zero; A=low byte of unsigned target-current difference,
; C=no-borrow sign from that subtraction, X=unsigned divisor (zero accepted).
; DP $0E/$0F must be zero for negation. Returns YA=signed 8.8 quotient and
; X=DP $44, not the incoming divisor. DP $12 is rotated; negative path uses
; $14/$15. For d>0: sign(delta)*floor(abs(delta)*256/d), modulo 65536.
; For d=0: signed magnitude 65535-abs(delta). Preserves PSW P/I/B; positive
; N/Z reflect restored X, C=old $12 bit 0, H/V from final DIV; negative
; N/Z/C/H/V reflect SUBW. Stack balanced; see docs/audio.md for E2 evidence.
    .org $0BC7
spcDivideStep:
    NOTC
    ROR $12                ; Borrow becomes sign bit; old bit zero becomes carry.
    BPL divideMagnitude
    EOR A, #$FF
    INC A                  ; Absolute magnitude of the full unsigned difference.

divideMagnitude:
    MOV Y, #$00
    DIV YA, X              ; Integer quotient and remainder, including SPC d=0.
    PUSH A
    MOV A, #$00
    DIV YA, X              ; Fraction = floor(remainder*256/divisor).
    POP Y                  ; YA now combines integer and fractional quotient.
    MOV X, $44             ; Restore caller's channel offset from global scratch.

; CALL entry $0BD9: YA=value, DP $12 bit 7=negate; DP $0E/$0F=0.
; Preserves X. Clear sign returns YA/PSW unchanged; set sign stores YA in
; $14/$15 and returns its negation with SUBW flags. Also divides' shared tail.
spcNegateStep:
    BBC $12.7, returnStep

    MOVW $14, YA
    MOVW YA, $0E           ; Driver's zero word; this is not an immediate zero.
    SUBW YA, $14           ; Shared return tail handles the negated magnitude.
returnStep:
    RET
