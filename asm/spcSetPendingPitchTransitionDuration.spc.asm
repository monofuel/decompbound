; Pending duration store, APU $0A82..0A85 / file $2605C4..2605C7 (4 bytes).
; Dispatcher/RET or CALL/RET: A=duration, X=even channel offset; either DP valid.
; F3 dispatch has no operand and supplies A=Y=0, disabling the next event's
; pending transition. Direct nonzero A sets duration instead of disabling.
; Preserves A/X/Y and all PSW bits; reads no stream bytes or DSP ports.
; Existing active $A0/$A1, pitch/step/target words and other pending fields
; remain unchanged until separate event setup or ticking. See docs/audio.md.
    .org $0A82
spcSetPendingPitchTransitionDuration:
    MOV $0280+X, A
    RET
