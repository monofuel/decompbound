; F4 event fraction source, APU $0AA8..0AAB / file $2605EA..2605ED (4 bytes).
; Dispatcher/RET or CALL/RET: A=prefetched byte, X=even channel offset 0..14.
; Either direct page works. Stores $0381+X; accepted-event preparation at
; $0674 later copies this byte into current fraction $0360+X.
; Preserves A/X/Y and all PSW bits. No further fetch or DSP writes; current
; pitch is unchanged by this store alone. See docs/audio.md for event setup.
    .org $0AA8
spcSetEventPitchFraction:
    MOV $0381+X, A
    RET
