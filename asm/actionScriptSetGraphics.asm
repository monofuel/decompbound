; Install an entity frame-table pointer from action opcode $1C.
; File $009B4D..$009B60, SNES $C09B4D. RTS handler, M16/X16, DBR=$7E.
; Y is at the operands of long stream pointer DP $80; DP $88 is the
; entity byte offset (index*2). Operand is a 16-bit table address plus
; an 8-bit bank. Returns A.low=bank, A.high=address high, X=entityOffset;
; Y advances by three with 16-bit wrap. Preserves D, DBR, and stack depth.
; Evidence: docs/graphics.md (entity frame tables).
    .a16
    .i16

    LDX $88                 ; Entity byte offset.
    LDA [$80],Y
    STA $112E,X             ; Frame-table address.
    INY
    INY

    ; Bank is stored 8-bit so neighboring high state $116B,X is preserved.
    SEP #$20
    .a8
    LDA [$80],Y             ; A.low gets the bank; A.high keeps address high.
    STA $116A,X             ; Table bank; $116B is adjacent state.
    REP #$20
    .a16
    INY
    RTS
