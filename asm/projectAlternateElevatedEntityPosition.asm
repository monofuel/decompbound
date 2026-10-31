; Project world X/Y against origin $0039/$003B, then subtract elevation.
; File $00A0A0..$00A0BA (27 bytes). JSR $C0A0A0: native M16/X16, decimal
; clear, DBR=$7E. DP+$88 is the entity byte offset; X is reloaded from it.
; renderX = worldX - $0039. renderY = worldY - $003B - $0C06, 16-bit wrap.
; Extra SEC drops the origin-Y borrow, matching $A03A's elevation rule.
; No clip. Preserves Y, D, DBR and stack depth; A/X and flags are scratch.
; Evidence: docs/scripts.md.

    .a16
    .i16

projectAlternateElevatedEntityPosition:
    LDX $88                 ; Scheduler entity offset.

    LDA $0B8E,X             ; World X integer.
    SEC
    SBC $0039               ; Origin X.
    STA $0B16,X             ; Render X.

    LDA $0BCA,X             ; World Y integer.
    SEC
    SBC $003B               ; Origin Y.
    SEC                     ; Drop origin borrow; elevation is its own 16-bit sub.
    SBC $0C06,X             ; Elevation integer.
    STA $0B52,X             ; Render Y.
    RTS
