; Add origin $0039/$003B back onto world X/Y. Render words are untouched.
; File $00A089..$00A09F (23 bytes). JSL $C0A089: native M16/X16, decimal
; clear, DBR=$7E. DP+$88 is the entity byte offset; X is reloaded from it.
; worldX += $0039, worldY += $003B, 16-bit wrap. Inverse of $C0A06C's
; world subtract; that sibling also wrote render, this one does not.
; Preserves Y, D, DBR and stack depth; A/X and flags are scratch.
; Evidence: docs/scripts.md.

    .a16
    .i16

restoreEntityPositionOrigin:
    LDX $88                 ; Scheduler entity offset.

    LDA $0B8E,X             ; World X integer.
    CLC
    ADC $0039               ; Origin X.
    STA $0B8E,X

    LDA $0BCA,X             ; World Y integer.
    CLC
    ADC $003B               ; Origin Y.
    STA $0BCA,X
    RTL
