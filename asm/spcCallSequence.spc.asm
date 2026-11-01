; Call/repeat sequence, APU $0AAC..$0ACE / file $2605EE..$260610 (35 bytes).
; Dispatcher/RET: DP zero, even channel X in 0..14, A=prefetched target low.
; Fetches target high and count; all three operand bytes are consumed. Stores
; target $0240/$0241+X, count $80+X and post-operands cursor $0230/$0231+X,
; then redirects cursor $30/$31+X. Only one software call slot exists per
; channel: nested calls overwrite it. Count zero does not encode 256 repeats.
; Preserves X and PSW except N/Z; returns A=target high, Y=count. Internal
; calls balance the hardware stack; no sequence frame remains. See docs/audio.md.
    .org $0AAC
spcCallSequence:
    MOV $0240+X, A
    CALL $0955             ; spcSequenceFetch: target high byte.
    MOV $0241+X, A
    CALL $0955             ; spcSequenceFetch: full unsigned repeat count.
    MOV $80+X, A

    ; Save the cursor after all operands, replacing any prior software return.
    MOV A, $30+X
    MOV $0230+X, A
    MOV A, $31+X
    MOV $0231+X, A

; CALL entry $0AC4: DP zero, X=channel; copy saved target to live cursor.
; Preserves X/Y and PSW except N/Z; returns A=target high through shared RET.
spcRestartSequence:
    MOV A, $0240+X
    MOV $30+X, A
    MOV A, $0241+X
    MOV $31+X, A
    RET
