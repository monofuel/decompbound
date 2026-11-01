; Project world X/Y like $A023, then subtract elevation from render Y.
; File $00A03A..$00A054 (27 bytes). JSR $C0A03A: native M16/X16, decimal
; clear, DBR=$7E. DP+$88 is the entity byte offset; X is reloaded from it.
; renderX = worldX - $0031. renderY = worldY - $0033 - $0C06, 16-bit wrap.
; Extra SEC after the scroll subtract drops that borrow, so elevation is
; a second independent 16-bit subtract, not a chained 32-bit difference.
; No clip. Preserves Y, D, DBR and stack depth; A/X and flags are scratch.
; Evidence: docs/scripts.md.

    .a16
    .i16

projectElevatedEntityPosition:
    LDX $88                 ; Scheduler entity offset.

    LDA $0B8E,X             ; World X integer.
    SEC
    SBC $0031               ; Scroll origin X.
    STA $0B16,X             ; Render X.

    LDA $0BCA,X             ; World Y integer.
    SEC
    SBC $0033               ; Scroll origin Y.
    SEC                     ; Drop scroll borrow; elevation is its own 16-bit sub.
    SBC $0C06,X             ; Elevation integer.
    STA $0B52,X             ; Render Y.
    RTS
