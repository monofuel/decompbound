; E9 global pitch offset, APU $0A52..0A54 / file $260594..260596 (3 bytes).
; Dispatcher/RET or CALL/RET: direct page zero, A=prefetched offset byte.
; Stores global $50. Accepted-event arithmetic at $0667 adds it modulo 256
; before the channel offset; no signed extension, clipping or carry chaining.
; Preserves A/X/Y and all PSW bits; fetches no further operands or DSP writes.
; Current pitch is unchanged until a later accepted event. See docs/audio.md.
    .org $0A52
spcSetGlobalPitchOffset:
    MOV $50, A
    RET
