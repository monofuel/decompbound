; EB configure modulation, APU $0A59..0A64 / file $26059B..2605A6 (12 bytes).
; Dispatcher entry: direct page zero, X=even channel offset, A=prefetched delay.
; Stores delay threshold $02E0+X, fetches rate into $02D1+X, then fetches depth
; for the shared $0A65 store/RET tail. Three operand bytes consumed in total.
; Preserves X and PSW except N/Z; tail returns A=Y=depth with N/Z from depth.
; Does not reset counter $C0+X or phase $02D0+X, mark dirty $5E, or write DSP.
; Depth is a full numeric byte; $FF has special handling in consumer $0C40.
; Internal calls balance; shared tail returns to caller. See docs/audio.md.
    .org $0A59
spcConfigureVolumeModulation:
    MOV $02E0+X, A         ; Delay threshold; existing counter is preserved.
    CALL $0955             ; Fetch phase increment and advance channel cursor.
    MOV $02D1+X, A
    CALL $0955             ; Fetch depth; no masking or phase reset.
    ; Fall through $0A65: spcSetVolumeModulationDepth's shared store/RET.
