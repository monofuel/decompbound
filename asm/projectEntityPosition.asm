; Project world X/Y into render coordinates against scroll $0031/$0033.
; File $00A023..$00A039 (23 bytes). JSR $C0A023: native M16/X16, decimal
; clear, DBR=$7E. DP+$88 is the entity byte offset; X is reloaded from it.
; renderX = worldX - $0031, renderY = worldY - $0033, 16-bit wrap, no clip.
; Each axis uses its own SEC. Default $11A6 callback; still runs while paused.
; Preserves Y, D, DBR and stack depth; A/X and flags are scratch.
; Evidence: docs/scripts.md.

    .a16
    .i16

projectEntityPosition:
    LDX $88                 ; Scheduler entity offset.

    LDA $0B8E,X             ; World X integer.
    SEC
    SBC $0031               ; Scroll origin X.
    STA $0B16,X             ; Render X.

    LDA $0BCA,X             ; World Y integer.
    SEC
    SBC $0033               ; Scroll origin Y.
    STA $0B52,X             ; Render Y.
    RTS
