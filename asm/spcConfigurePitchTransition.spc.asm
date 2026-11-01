; Configure pending pitch transition, APU $0A68..0A81 / file $2605AA..2605C3.
; Dispatcher/CALL entries below: DP zero, X=even channel offset, Y=delay byte.
; F1/F2 dispatch has already fetched that first operand into A/Y; input A is
; discarded. Fetches duration and raw interval bytes, then returns A=Y=interval.
; Preserves X and PSW C/H/V/P/I/B; N/Z reflect interval. Internal calls balance.
; Writes pending fields only; active $A0/$A1, $0360/$0370/$0380 words unchanged.
; No DSP writes or dirty marking. See docs/audio.md for event setup/consumers.
    .org $0A68
spcConfigurePitchTransitionModeOne:
    MOV A, #$01            ; F1: accepted-event setup retains its starting integer.
    BRA storeParameters

; F2 entry $0A6C: same contract, selecting zero mode. Event setup first
; subtracts the interval from its starting integer; arithmetic wraps at 8 bits.
spcConfigurePitchTransitionModeZero:
    MOV A, #$00

; Shared entry $0A6E: A=arbitrary mode byte, Y=delay, X=channel offset.
; Only zero versus nonzero is tested by the accepted-event setup consumer.
storeParameters:
    MOV $0290+X, A
    MOV A, Y
    MOV $0281+X, A         ; Delay is the original first operand preserved in Y.
    CALL $0955             ; Fetch duration and advance channel cursor.
    MOV $0280+X, A
    CALL $0955             ; Fetch full interval byte; no signed extension here.
    MOV $0291+X, A
    RET
