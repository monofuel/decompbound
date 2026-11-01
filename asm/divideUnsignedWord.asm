; Unsigned word division, file $00915B..00917B / SNES $C0915B (33B).
; Native JSL/RTL, M16/X16, decimal clear. A=dividend, Y=divisor; DBR selects
; writable scratch words $00B0/$00B2 (normally $7E); D is unused/preserved.
; Scratch must be disjoint from the live native return frame.
; Return A=quotient, Y=remainder; divisor0 returns A=$FFFF,Y=dividend.
; Preserve X/DBR/D and incoming C; N/Z follow quotient, V follows the last
; executed SBC (or incoming V if none). Other status bits remain unchanged.
; Scratch $B2=divisor, $B0=(quotient>>1)|(incoming C<<15). No operand checks.
; The preceding $C0914B magnitude adapter falls through here; direct callers
; enter $C0915B without that signed-input transformation.
    .a16
    .i16
divideUnsignedWord:
    STA $00B0
    STY $00B2
    LDA #$0000
    LDY #$0010
unsignedDivisionBit:
    ROL $00B0              ; Shift dividend bit into C; injected entry C survives to the end.
    ROL A
    CMP $00B2
    BCC unsignedDivisionKeepRemainder
    SBC $00B2              ; CMP supplies no-borrow carry; quotient bit becomes next C.
unsignedDivisionKeepRemainder:
    DEY
    BNE unsignedDivisionBit
    TAY
    LDA $00B0
    ROL A                  ; Append the last quotient bit; recover incoming C.
    RTL
