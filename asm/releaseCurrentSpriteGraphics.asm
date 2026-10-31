; Release the current entity's sprite definition records and tile tags.
; File $0020F1..$00213F (79 bytes). Native JSL $C020F1 / RTL.
; DBR=$7E, decimal clear, M16/X16. Entity ID comes from $1A42. The entity
; and its action-script state stay allocated. VRAM is not cleared.
; Temporary DP at caller D-$10. Preserves D, DBR and stack depth.
; Details: docs/graphics.md (Sprite cleanup and reuse).
    .a16
    .i16
releaseCurrentSpriteGraphics:
    REP #$31
    PHD
    TDC
    ADC #$FFF0              ; D := D-$10
    TCD
    LDA $1A42
    STA $02                 ; current entity ID
    ASL A
    TAY
    STY $0E                 ; entity byte offset

    LDA $112E,Y
    JSL $C01B15             ; releaseSpriteDefinitions
    LDX #$0000              ; free matching occupancy bytes
    LDA $02
    JSL $C01C11             ; replaceSpriteSlotTags

    LDY $0E
    LDA $2C9A,Y
    AND #$F000
    CMP #$8000
    BNE skipCategoryDec
    ; TODO: $2C9A top nibble $8 decrements $4A5C (16-bit wrap, 0 -> $FFFF).
    DEC $4A5C
skipCategoryDec:
    LDA $02
    ASL A
    TAX
    LDA $2D12,X
    CMP #$00E1
    BNE skipEffectClear
    ; TODO: $2D12 == $00E1 clears $4A60; category meaning is open.
    STZ $4A60
skipEffectClear:
    LDA $02
    ASL A
    TAX
    LDA #$FFFF
    STA $2CD6,X             ; resource ID
    STA $2C9A,X
    PLD
    RTL
