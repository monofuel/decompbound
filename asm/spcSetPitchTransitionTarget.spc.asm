; Set pitch target/step, APU $0BA4..$0BBB / file $2606E6..$2606FD (24 bytes).
; CALL/RET: DP zero, even channel X, A=raw target byte, duration at $A0+X.
; Requires DP $44=X and word $0E/$0F=0; stores target A&$7F at $0380+X.
; Delta is masked target minus current integer $0361+X, with full borrow sign.
; Writes signed 8.8 step to $0370/$0371+X through the shared divider; current
; fraction is ignored. Zero duration uses the divider's zero-divisor law.
; Returns X=$44, A=Y=step high; P/I/B preserved, C/H/V from divider and N/Z
; from step high. Uses DP $12 and negative-path $14/$15. See docs/audio.md.
    .org $0BA4
spcSetPitchTransitionTarget:
    AND A, #$7F
    MOV $0380+X, A
    SETC
    SBC A, $0361+X
    MOV Y, $A0+X
    PUSH Y
    POP X                  ; Divisor replaces channel index without altering carry.
    CALL $0BC7             ; spcDivideStep restores channel X from DP $44.
    MOV $0370+X, A
    MOV A, Y
    MOV $0371+X, A
    RET
