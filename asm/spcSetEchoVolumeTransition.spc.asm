; Set echo-volume fade, APU $0AE2..$0B02 / file $260624..$260644 (33 bytes).
; Dispatcher/RET: DP zero, X=channel, A=prefetched duration; requires $44=X
; and word $0E/$0F=0 for signed division. Fetches full left/right target bytes.
; Stores duration $68, targets $69/$6A, steps $64/$65 and $66/$67. Current
; $60..$63 remain unchanged; each step ignores its current fractional byte.
; Returns X=$44 and YA=right step; PSW follows the second shared division.
; Uses DP $12 and negative-path $14/$15. No DSP writes or FLG/mask changes.
; Zero duration calculates both steps but disables ticking. See docs/audio.md.
    .org $0AE2
spcSetEchoVolumeTransition:
    MOV $68, A
    CALL $0955             ; spcSequenceFetch: left target.
    MOV $69, A
    SETC
    SBC A, $61
    MOV X, $68
    CALL $0BC7             ; spcDivideStep restores channel X from saved $44.
    MOVW $64, YA

    CALL $0955             ; Right target fetch uses the restored channel cursor.
    MOV $6A, A
    SETC
    SBC A, $63
    MOV X, $68
    CALL $0BC7
    MOVW $66, YA
    RET
