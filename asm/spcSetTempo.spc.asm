; E7 set tempo, APU $0A3B..0A3F / file $26057D..260581 (5 bytes).
; Dispatcher/RET: direct page zero; Y=prefetched tempo byte (also supplied in A).
; Writes global 8.8 tempo $52/$53 as Y*256, clearing the fractional byte.
; Pending transition $54/$55/$56/$57 is preserved, so this does not cancel it.
; Preserves X/Y and PSW C/H/V/P/I/B; returns A=0, N=0, Z=1.
; No further stream reads or DSP writes. See docs/audio.md for phase consumers.
    .org $0A3B
spcSetTempo:
    MOV A, #$00
    MOVW $52, YA           ; Phase production uses the high byte $53.
    RET
