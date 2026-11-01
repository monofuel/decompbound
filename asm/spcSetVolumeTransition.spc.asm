; Set volume transition, APU $0A8F..$0AA7 / file $2605D1..$2605E9 (25 bytes).
; Dispatcher/RET: DP zero, even X in 0..14, DP $44=X, word $0E/$0F zero.
; A=duration already fetched; consumes one more byte as full unsigned target.
; Stores duration at $90+X, target at $0320+X and signed 8.8 step $0310/$0311+X.
; Step ignores current fraction: sign(delta)*floor(abs(delta)*256/duration),
; delta=target-$0301+X. Zero duration uses the shared SPC division edge case.
; Preserves current $0300/$0301+X, X and dirty mask; clobbers A/Y/PSW and
; helper scratch $12/$14/$15. No DSP writes or $0431 override. See docs/audio.md.
    .org $0A8F
spcSetVolumeTransition:
    MOV $90+X, A
    PUSH A                 ; Preserve duration while advancing the stream.
    CALL $0955             ; spcSequenceFetch: second operand is target volume.
    MOV $0320+X, A
    SETC
    SBC A, $0301+X         ; Borrow encodes the full signed target difference.
    POP X                  ; Divisor replaces channel X until helper restores it.
    CALL $0BC7             ; spcDivideStep; restores X from DP $44.
    MOV $0310+X, A
    MOV A, Y
    MOV $0311+X, A
    RET
