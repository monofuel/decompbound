; Build both runtime sprite-definition variants from one resource layout.
; File $001D38..$001DEC; JSR $C01D38, native M16/X16, DBR=$7E, decimal clear.
; In: A=definition-pool offset, X=tile slot, Y.low=resource attributes;
;     caller DP+$0E points to the layout. Scratch uses caller D-$1A.
; Out: A=records per variant, Y=2, X=initial offset+10*A (16-bit).
; Preserves: D, DBR and stack depth. Writes both variants at $467E+offset.
; Layout and verification: docs/graphics.md#runtime-definition-builder.
    .a16
    .i16

    ; Save the caller's scratch base and keep the construction inputs locally.
    REP #$31
    PHD
    PHA
    TDC
    ADC #$FFE6
    TCD
    PLA
    STY $18                ; Resource attribute bits.
    STX $04                ; First allocated tile slot.
    TAX                    ; Output offset into the definition pool.

    ; Copy the layout pointer from the caller's direct page.
    LDA $28
    STA $06
    LDA $2A
    STA $08
    LDA [$06]
    AND #$00FF             ; Header byte 0: records in each variant.
    STA $02
    STA $16
    INC $06
    INC $06                ; Skip the two-byte layout header.
    LDY #$0000
    STY $14                ; Current variant, 0 or 1.
    JMP checkVariantCount

beginVariant:
    ; Both variants start at the same tile slot; source records stay consecutive.
    LDA #$0000
    STA $12                ; Record index within this variant.
    BRA checkRecordCount

copyRecord:
    SEP #$20
    .a8
    LDA [$06]
    STA $467E,X            ; Signed Y displacement.
    INX
    STX $10                ; Save output cursor while X indexes the tile table.
    REP #$20
    .a16

    ; Replace the layout's tile byte with the allocated slot's tile word.
    LDA $12
    STA $02
    LDA $04
    CLC
    ADC $02
    ASL A
    TAX
    LDA $C4303C,X           ; Tile word for slot + record index.
    STA $0E
    SEP #$20
    .a8
    LDX $10
    STA $467E,X            ; Low tile byte.
    INX

    ; Attribute bit 0 comes from the tile word, combined with resource flags.
    REP #$20
    .a16
    LDA $0E
    XBA
    AND #$00FF
    SEP #$20
    .a8
    STA $00                ; Tile-word high byte.
    REP #$20
    .a16
    LDA $18
    SEP #$20
    .a8
    STA $01                ; Resource attribute modifier.
    LDY #$0002
    LDA [$06],Y            ; Layout attributes.
    AND #$FE
    ORA $01
    ORA $00
    STA $467E,X
    INX

    ; Preserve the remaining layout fields, including each variant's terminator.
    LDY #$0003
    LDA [$06],Y
    STA $467E,X            ; Signed X displacement.
    INX
    LDY #$0004
    LDA [$06],Y
    STA $467E,X            ; Size bit and last-record flag.
    INX
    REP #$20
    .a16

    ; Advance within this bank; the source pointer's bank does not increment.
    LDA #$0005
    CLC
    ADC $06
    STA $06
    LDA $12
    INC A
    STA $12

checkRecordCount:
    LDY $16
    STY $02
    CMP $02
    BCC copyRecord
    LDY $14
    INY
    STY $14

checkVariantCount:
    CPY #$0002
    BCS finishVariants
    BEQ finishVariants
    JMP beginVariant

finishVariants:
    PLD
    RTS
