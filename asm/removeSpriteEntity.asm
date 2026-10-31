; Release sprite graphics for an explicit entity ID, then remove the entity.
; File $002140..$002193 (84 bytes). Native JSL $C02140 / RTL.
; DBR=$7E, decimal clear, M16/X16. A=entity ID. Graphics cleanup matches
; releaseCurrentSpriteGraphics, then removeEntityById $C09C35 unlinks the
; entity and returns its script-state chain. VRAM is not cleared.
; Temporary DP at caller D-$10. Preserves D, DBR and stack depth.
; Details: docs/graphics.md (Sprite cleanup and reuse).
    .a16
    .i16
removeSpriteEntity:
    REP #$31
    PHD
    PHA                     ; keep entity ID across the D change
    TDC
    ADC #$FFF0              ; D := D-$10
    TCD
    PLA
    STA $02                 ; explicit entity ID
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

    LDA $02
    JSL $C09C35             ; removeEntityById
    PLD
    RTL
