; Fetch next sequence token, APU $0882..$089D / file $2603C4..$2603DF (28 bytes).
; Parser fall-through/branch entry: DP zero, even channel X in 0..14.
; Nonzero token advances cursor $30/$31+X and continues at $089E with A=Y=token.
; Zero with count $80+X=0 enters global control reader $081A without decrement.
; Otherwise reloads target $0240+X, decrements count, and restores return
; $0230+X when it reaches zero; then fetches again. Count zero is not 256.
; Preserves X and PSW except N/Z; clobbers A/Y. Internal CALLs balance SP;
; this region does not RET. See docs/audio.md for call-slot and zero handling.
    .org $0882
spcFetchSequenceEvent:
    CALL $0955             ; spcSequenceFetch: cursor advances even for zero.
    BNE $089E              ; Continue into nonzero prefix/event/command parsing.
    MOV A, $80+X
    BEQ $081A              ; spcReadSequenceControl; no active software call.

    CALL $0AC4             ; spcRestartSequence: restore target before decrement.
    DEC $80+X
    BNE spcFetchSequenceEvent
    MOV A, $0230+X         ; Exhaustion replaces the just-reloaded target.
    MOV $30+X, A
    MOV A, $0231+X
    MOV $31+X, A
    BRA spcFetchSequenceEvent
