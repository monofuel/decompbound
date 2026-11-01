; EA channel pitch offset, APU $0A55..0A58 / file $260597..26059A (4 bytes).
; Dispatcher/RET or CALL/RET: A=prefetched offset, X=even channel offset 0..14.
; Either direct page works. Stores byte $02F0+X, added modulo 256 after the
; global $50 offset on the accepted-event path at $066E.
; Preserves A/X/Y and all PSW bits; no further fetch, current-pitch or DSP writes.
; All eight bits participate; no separate sign flag exists. See docs/audio.md.
    .org $0A55
spcSetChannelPitchOffset:
    MOV $02F0+X, A
    RET
