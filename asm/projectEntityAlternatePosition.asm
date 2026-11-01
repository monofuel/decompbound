; Project world X/Y into render coordinates against origin $0039/$003B.
; File $00A055..$00A06B (23 bytes). JSR $C0A055: native M16/X16, decimal
; clear, DBR=$7E. DP+$88 is the entity byte offset; X is reloaded from it.
; renderX = worldX - $0039, renderY = worldY - $003B, 16-bit wrap, no clip.
; Same shape as $A023 with a different origin pair. Preserves Y, D, DBR
; and stack depth; A/X and flags are scratch. Evidence: docs/scripts.md.

    .a16
    .i16

projectEntityAlternatePosition:
    LDX $88                 ; Scheduler entity offset.

    LDA $0B8E,X             ; World X integer.
    SEC
    SBC $0039               ; Origin X.
    STA $0B16,X             ; Render X.

    LDA $0BCA,X             ; World Y integer.
    SEC
    SBC $003B               ; Origin Y.
    STA $0B52,X             ; Render Y.
    RTS
