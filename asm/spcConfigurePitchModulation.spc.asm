; E3 pitch modulation, APU $09FD..0A08 / file $26053F..26054A (12 bytes).
; Dispatcher entry: DP zero, X=even channel offset, A=prefetched delay byte.
; Stores delay $02B0+X, fetches rate $02A1+X, then fetches depth for the
; shared $0A09 tail. Three operand bytes total; no masking or DSP writes.
; Preserves X and PSW except N/Z; shared tail returns A=0, Y=depth, N=0/Z=1.
; Does not reset delay counter $B0+X, ramp counter $0100+X or phase $02A0+X.
; Calls balance before fall-through store/RET tail. See docs/audio.md.
    .org $09FD
spcConfigurePitchModulation:
    MOV $02B0+X, A
    CALL $0955             ; Advancing fetch supplies the full byte phase rate.
    MOV $02A1+X, A
    CALL $0955             ; Fetch depth, then share E4's general depth-setting tail.
    ; Fall through $0A09: spcSetPitchModulationDepth.
