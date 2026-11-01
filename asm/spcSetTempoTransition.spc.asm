; E8 tempo transition, APU $0A40..0A51 / file $260582..260593 (18 bytes).
; Dispatcher/RET: direct page zero, X=channel offset, A=prefetched duration.
; DP $44 must hold channel X and $0E/$0F must be zero for signed division.
; Fetches target byte; stores global duration $54, target $55, signed step $56/$57.
; Leaves current tempo $52/$53 unchanged; step ignores its fractional byte $52.
; Zero duration still computes the helper's zero-divisor result but disables ticks.
; Returns X=DP $44, YA=step; uses $12 and negative-path $14/$15. PSW follows
; $0BC7; P/I/B preserved. No DSP writes. See docs/audio.md for scheduling.
    .org $0A40
spcSetTempoTransition:
    MOV $54, A
    CALL $0955             ; Fetch target into A/Y and advance channel cursor.
    MOV $55, A
    SETC
    SBC A, $53             ; Full unsigned-byte displacement, including borrow.

    MOV X, $54             ; Helper takes divisor X, then restores X from $44.
    CALL $0BC7             ; Signed displacement*256/duration, modulo 65536.
    MOVW $56, YA
    RET
