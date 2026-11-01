; Copy world X/Y into render coordinates with no origin or elevation.
; File $00A0BB..$00A0C9 (15 bytes). JSR $C0A0BB: native M16/X16, DBR=$7E.
; DP+$88 is the entity byte offset; X is reloaded from it. renderX =
; worldX, renderY = worldY. Decimal is unused. Preserves Y, D, DBR and
; stack depth; A/X and flags are scratch. Evidence: docs/scripts.md.

    .a16
    .i16

copyEntityPositionToRender:
    LDX $88                 ; Scheduler entity offset.

    LDA $0B8E,X             ; World X integer.
    STA $0B16,X             ; Render X.

    LDA $0BCA,X             ; World Y integer.
    STA $0B52,X             ; Render Y.
    RTS
