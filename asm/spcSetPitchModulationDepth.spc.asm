; E4/general depth tail, APU $0A09..0A13 / file $26054B..260555 (11 bytes).
; Dispatcher/RET, CALL/RET or E3 fall-through: DP zero, X=channel, A=depth.
; E4 dispatch supplies zero; direct nonzero A sets depth instead of disabling.
; Writes current depth $B1+X and saved depth $02C1+X, clears duration $02B1+X.
; Preserves X/Y and PSW C/H/V/P/I/B; returns A=0, N=0/Z=1.
; Counters $B0/$0100+X, phase/rate/delay and quotient $02C0+X are preserved.
; No further stream reads or DSP writes. See docs/audio.md for the consumer.
    .org $0A09
spcSetPitchModulationDepth:
    MOV $B1+X, A
    MOV $02C1+X, A
    MOV A, #$00
    MOV $02B1+X, A         ; A zero duration does not reset the existing ramp counter.
    RET
