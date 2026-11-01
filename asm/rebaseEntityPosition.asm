; Subtract origin $0039/$003B from world X/Y and copy the result to render.
; File $00A06C..$00A088 (29 bytes). JSL $C0A06C: native M16/X16, decimal
; clear, DBR=$7E. DP+$88 is the entity byte offset; X is reloaded from it.
; worldX -= $0039, worldY -= $003B, then render receives those new world
; words. 16-bit wrap, no elevation, no clip. Inverse world add is $C0A089.
; Preserves Y, D, DBR and stack depth; A/X and flags are scratch.
; Evidence: docs/scripts.md.

    .a16
    .i16

rebaseEntityPosition:
    LDX $88                 ; Scheduler entity offset.

    LDA $0B8E,X             ; World X integer.
    SEC
    SBC $0039               ; Origin X.
    STA $0B8E,X             ; Rebased world X.
    STA $0B16,X             ; Render X matches the new world X.

    LDA $0BCA,X             ; World Y integer.
    SEC
    SBC $003B               ; Origin Y.
    STA $0BCA,X             ; Rebased world Y.
    STA $0B52,X             ; Render Y matches the new world Y.
    RTL
