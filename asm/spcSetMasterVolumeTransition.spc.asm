; E6 master transition, APU $0A29..0A3A / file $26056B..26057C (18 bytes).
; Dispatcher/RET: direct page zero, X=channel offset, A=prefetched duration.
; DP $44 must hold channel X; $0E/$0F must be zero for signed division.
; Fetches target $5B, stores duration $5A and signed 8.8 step $5C/$5D.
; Leaves current $58/$59 and dirty mask $5E unchanged; calculation ignores
; fraction $58. Zero duration computes the helper result but disables ticking.
; Returns X=DP $44, YA=step; uses $12 and negative-path $14/$15. PSW follows
; $0BC7; P/I/B preserved. No DSP writes. See docs/audio.md for gain consumers.
    .org $0A29
spcSetMasterVolumeTransition:
    MOV $5A, A
    CALL $0955             ; Fetch target and advance the originating channel PC.
    MOV $5B, A
    SETC
    SBC A, $59             ; Full unsigned integer displacement, including borrow.

    MOV X, $5A
    CALL $0BC7             ; Signed displacement*256/duration; restores X from $44.
    MOVW $5C, YA
    RET
