; Dispatch one raw entity ID to its graphics callback.
; File $00A0CA..$00A0E2 (25 bytes), nominal SNES $C0A0CA; JSR/RTS.
; Native X16, decimal clear, DBR=$7E; REP establishes M16 only.
; A is a nonnegative raw ID (valid slots 0..29), not a doubled list link.
; Use the $80 (or $00) mirror: $A0E3's JMP ($11E2,X) needs WRAM there.
; D becomes (caller D-$A0)&$FF00. Reserve its scratch through $8F separately
; from the caller's locals; callbacks must preserve D/DBR and return M16/X16.
; Restores caller D; A/X/Y/flags and nested DP scratch are clobbered.
; Dispatch also requires V clear: the scratch SBC supplies inherited V.
; Evidence: docs/graphics.md and docs/expanded-viewport.md.
    .a16
    .i16

drawEntityById:
    REP #$20
    ; Isolate callback DP ($88 entity offset, $8C/$8E definition pointer).
    PHD
    PHA
    TDC
    SEC
    SBC #$00A0
    AND #$FF00
    TCD
    PLA

rejectNegativeId:
    ; Negative IDs deliberately spin forever; there is no upper-bound check.
    BMI rejectNegativeId
    ASL A
    TAX
    STX $88
    ; $A0E3 rejects negative bank/state, inherited V, or negative frame.
    ; Otherwise tail-JMP dispatches $11E2,X; callback RTS returns here.
    JSR $A0E3
    PLD
    RTS
