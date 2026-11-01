; EC disable/shared depth tail, APU $0A65..0A67 / file $2605A7..2605A9 (3 bytes).
; Dispatcher/RET, CALL/RET or EB fall-through: direct page zero, X=channel offset.
; Stores A as numeric depth at $C1+X. EC dispatch supplies A=Y=0 because its
; operand metadata is zero; a direct nonzero A enables depth rather than disabling.
; Preserves A/X/Y and all PSW bits; no operands fetched or DSP writes.
; Does not reset phase/counter or alter delay/rate and dirty mask $5E.
; Depth zero makes $0C40 preserve phase/counter and use gain factor 255.
; See docs/audio.md for the downstream modulation and dirty-output gates.
    .org $0A65
spcSetVolumeModulationDepth:
    MOV $C1+X, A
    RET
