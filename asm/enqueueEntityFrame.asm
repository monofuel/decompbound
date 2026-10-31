; Enqueue the selected frame definition for the current entity.
; File $00A0FA..$00A11A, SNES $C0A0FA. JMP from dispatchEntityGraphics
; when $11E2,X is $A0FA. Native M16/X16, DBR=$7E. A is a nonnegative
; frame index from $10F2,X; X is the entity byte offset. The appender
; RTS returns to the original dispatch caller.
; Tile and attribute bytes come from the five-byte records, unchanged.
; Evidence: docs/graphics.md (entity frame tables).
    .a16
    .i16

enqueueEntityFrame:
    ; Convert the frame index to a byte offset; table bounds are unchecked.
    ASL A
    TAY

    ; Copy the table bank 8-bit so neighboring $000C is preserved.
    SEP #$20
    .a8
    LDA $8E                 ; Bank installed by dispatch at DP $8E.
    STA $000B               ; Definition bank for enqueue/emit.
    REP #$20
    .a16

    LDA [$8C],Y             ; Definition pointer at frame index.
    STA $96
    LDA $103E,X
    STA $2400               ; Queue group 0..3.
    LDY $0BCA,X             ; Origin Y.
    LDA $0B8E,X             ; Origin X.
    TAX
    LDA $96
    JMP $8C58               ; enqueueOamDefinition near entry.
