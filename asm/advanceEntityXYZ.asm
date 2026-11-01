; Advance world X/Y, then the same 32-bit add on Z/elevation.
; File $00A00C..$00A022 (23 bytes). JSR $C0A00C: native M16/X16, decimal
; clear, DBR=$7E. DP+$88 is the entity byte offset; $9FC8 reloads X from it.
; Z uses fraction $0CBA and integer $0C06 with steps $0E22 / $0D6E. The Z
; CLC drops leftover Y carry. Sibling $C09FF1 also calls $C0C7DB and is
; not this file. Preserves Y, D, DBR and stack depth; A/X and flags are
; scratch. Evidence: docs/scripts.md.

    .a16
    .i16

advanceEntityXYZ:
    JSR $9FC8               ; advanceEntityXY; X becomes the entity offset.

    ; Independent 32-bit Z add. $0C06 is the elevation integer projection uses.
    LDA $0CBA,X             ; Z fraction.
    CLC
    ADC $0E22,X             ; Z fraction step.
    STA $0CBA,X
    LDA $0C06,X             ; Elevation / Z integer.
    ADC $0D6E,X             ; Z integer step plus fraction carry.
    STA $0C06,X
    RTS
