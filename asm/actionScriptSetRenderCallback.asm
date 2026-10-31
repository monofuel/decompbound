; Install an entity graphics callback from action opcode $22.
; File $009BE4..$009BED, SNES $C09BE4. RTS handler, M16/X16, DBR=$7E.
; Y is at the operands of long stream pointer DP $80; DP $88 is the
; entity byte offset. Operand is a 16-bit callback address. Returns
; A=callback, X=entityOffset; Y advances by two with 16-bit wrap.
; Preserves D, DBR, and stack depth. $A0FA is the table-index callback.
; Evidence: docs/graphics.md (entity frame tables).
    .a16
    .i16

    LDA [$80],Y
    LDX $88                 ; Entity byte offset.
    STA $11E2,X             ; Graphics callback word.
    INY
    INY
    RTS
