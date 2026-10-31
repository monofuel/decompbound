; Create a sprite entity from a resource ID, script selector, and owner.
; File $001E49..$0020F0 (680 bytes). Native JSL $C01E49 / RTL.
; DBR=$7E, decimal clear, M16/X16. A=resource ID, X=script selector,
; Y=owner request; caller DP+$0E/+$10 are X/Y coordinates in pixels.
; Out: A=entity ID on success. Preserves D, DBR and stack depth.
; Allocation failures spin; constructor failure carry is not checked.
; Temporary DP at caller D-$31; nested scratch must stay off entity arrays.
; Details: docs/graphics.md (Complete sprite spawn wrapper).
    .a16
    .i16
spawnSpriteEntity:
    REP #$31
    PHD
    PHA
    TDC
    ADC #$FFCF              ; D := D-$31
    TCD
    PLA
    STY $04                 ; owner request
    PHA
    LDA $04
    STA $2F                 ; saved owner
    PLA
    STX $2D                 ; script selector
    STA $2B                 ; resource ID
    LDY $41                 ; caller DP+$10 Y coordinate
    STY $29
    LDX $3F                 ; caller DP+$0E X coordinate
    STX $27

    ; Resource ID $FFFF with $436C set returns A=0 before allocation.
    ; Owner $FFFF is a later temporary-tag path, not this gate.
    ; TODO: meaning of $436C is open.
    LDA $436C
    BEQ lookupResource
    LDA $2B
    CMP #$FFFF
    BNE lookupResource
    LDA #$0000
    JMP returnEntity

lookupResource:
    LDA #$133F
    STA $0A
    LDA #$00EF
    STA $0C                 ; pointer table $EF133F
    LDA $2B
    ASL A
    ASL A
    CLC
    ADC $0A
    STA $0A                 ; table + resource ID * 4
    LDY #$0002
    LDA [$0A],Y
    TAY
    LDA [$0A]
    STA $06
    STY $08                 ; resource far pointer
    LDA $06
    STA $23
    LDA $08
    STA $25

    ; Nested header reader uses D-$10 below this frame; $04 owner survives.
    LDA $2B
    JSR $1DED               ; width $467A, height $467C, A=layout ID
    STA $02
    LDY $04                 ; owner tag
    LDX $467C               ; height, 8-pixel tiles
    LDA $467A               ; width, 8-pixel tiles
    JSL $C01C52             ; allocateAndClearSpriteTiles
    STA $21

waitForTileSlots:
    ; Failure $FF03 spins here; the loop does not retry allocation.
    LDA $21
    CMP #$7FFF
    BEQ lookupLayout
    BCS waitForTileSlots

lookupLayout:
    LDA #$2B0D
    STA $06
    LDA #$00C4
    STA $08                 ; layout pointer table $C42B0D
    LDA $02
    ASL A
    ASL A
    CLC
    ADC $06
    STA $06                 ; table + layout ID * 4
    LDY #$0002
    LDA [$06],Y
    TAY
    LDA [$06]
    STA $0A
    STY $0C                 ; layout far pointer
    LDA [$0A]
    AND #$00FF
    STA $04                 ; layout record count
    ASL A
    ASL A
    ADC $04
    ASL A                   ; count * 10 bytes for two variants
    JSL $C01A9D             ; findSpriteDefinitionSpace
    STA $1F

waitForDefinitionSpace:
    ; Failure $FF01/$FF02 spins here; the loop does not retry the finder.
    LDA $1F
    CMP #$7FFF
    BEQ prepareConstructor
    BCS waitForDefinitionSpace

prepareConstructor:
    LDA #$0001
    STA $0A4A               ; rendering queue 1
    LDA $0A
    STA $06
    LDA $0C
    STA $08
    LDA $06
    STA $0E                 ; builder layout pointer at DP+$0E
    LDA $08
    STA $10
    LDA $23
    STA $06
    LDA $25
    STA $08                 ; restore resource far pointer
    SEP #$20
    .a8
    LDY #$0003
    LDA [$06],Y             ; resource byte 3, attribute modifier
    REP #$20
    .a16
    AND #$00FF
    TAY
    LDX $21                 ; tile slot
    LDA $1F                 ; definition offset
    JSR $1D38               ; buildSpriteDefinitions

    LDA $2F
    STA $04
    CMP #$FFFF
    BEQ autoOwner

    ; Explicit owner: request that exact entity ID; occupancy is already tagged.
    LDA $04
    STA $0A4C
    LDA $04
    INC A
    STA $0A4E
    LDY $29
    LDX $27
    LDA $2D                 ; script selector
    JSL $C09321             ; createEntity; carry is not inspected
    STA $02
    BRA attachDefinition

autoOwner:
    ; Temporary $FFFF tags: constructor may pick ID 0..21, then retag occupancy.
    STZ $0A4C
    LDA #$0016
    STA $0A4E               ; exclusive upper ID 22
    LDY $29
    LDX $27
    LDA $2D
    JSL $C09321             ; createEntity; carry is not inspected
    STA $02
    ORA #$0080
    TAX                     ; replacement tag = new entity ID | $80
    LDA #$FFFF              ; select occupancy still tagged $FF
    JSL $C01C11             ; replaceSpriteSlotTags

attachDefinition:
    ; Field stores use A as an ID even if construction failed.
    LDA $02
    ASL A
    TAY
    STY $1D                 ; entity byte offset
    LDA $1F
    CLC
    ADC #$467E
    STA $112E,Y             ; definition pointer
    LDA #$007E
    STA $116A,Y             ; definition bank
    LDA [$0A]
    AND #$00FF
    STA $04
    ASL A
    ASL A
    ADC $04
    STA $2916,Y             ; variant stride = count * 5
    LDA $21
    STA $2952,Y             ; tile slot

    TYA
    CLC
    ADC #$298E
    TAX
    STX $1B                 ; address of upload destination
    LDA $21
    ASL A
    TAX
    LDA $C42F8C,X           ; slot VRAM word
    CLC
    ADC #$4000
    LDX $1B
    STA $0000,X             ; $298E upload destination

    SEP #$20
    .a8
    LDY #$0001
    LDA [$06],Y             ; resource byte 1
    REP #$20
    .a16
    AND #$00FF
    ASL A
    LDY $1D
    STA $2A7E,Y             ; bytes per chunk
    LDA [$06]
    AND #$00FF
    STA $2ABA,Y             ; chunk count = resource byte 0
    LDA $23
    STA $06
    LDA $25
    STA $08
    SEP #$20
    .a8
    LDY #$0008
    LDA [$06],Y             ; resource byte 8
    REP #$20
    .a16
    AND #$00FF
    LDY $1D
    STA $2A42,Y             ; graphics bank

    LDA #$133F
    STA $06
    LDA #$00EF
    STA $08
    LDA $2B
    ASL A
    ASL A
    CLC
    ADC $06
    STA $06
    LDY #$0002
    LDA [$06],Y
    TAY
    LDA [$06]
    STA $06
    STY $08
    LDA $06
    STA $12
    LDA $08
    STA $14                 ; resource far pointer again
    LDA $2B
    LDY $1D
    STA $2CD6,Y             ; resource ID
    LDA $14
    STA $2A06,Y             ; resource bank
    LDA $12
    CLC
    ADC #$0009
    STA $29CA,Y             ; inline graphics-entry list at resource+9

    LDA $467C
    AND #$0001
    BEQ storeLayoutId
    LDA $0000,X
    CLC
    ADC #$0100              ; odd height: dest += $100 VRAM words
    STA $0000,X

storeLayoutId:
    LDA $02
    ASL A
    TAX
    STX $1B                 ; entity offset as X
    LDA $23
    STA $06
    LDA $25
    STA $08
    INC $06
    INC $06                 ; resource+2, layout ID byte
    LDA $06
    STA $17
    LDA $08
    STA $19
    LDA [$17]
    AND #$00FF
    STA $2B6E,X             ; layout ID

    ; Resource bytes 4-7. TODO: field meanings remain open.
    LDA $23
    STA $06
    LDA $25
    STA $08
    SEP #$20
    .a8
    LDY #$0004
    LDA [$06],Y
    REP #$20
    .a16
    AND #$00FF
    STA $3366,X
    SEP #$20
    .a8
    LDY #$0005
    LDA [$06],Y
    REP #$20
    .a16
    AND #$00FF
    STA $33A2,X
    SEP #$20
    .a8
    LDY #$0006
    LDA [$06],Y
    REP #$20
    .a16
    AND #$00FF
    STA $33DE,X
    SEP #$20
    .a8
    LDY #$0007
    LDA [$06],Y
    REP #$20
    .a16
    AND #$00FF
    STA $1A4A,X

    LDA [$17]
    AND #$00FF
    ASL A
    TAX
    LDA $C42AEB,X           ; layout-indexed word
    LDX $1B
    STA $332A,X

    SEP #$20
    .a8
    LDY #$0001
    LDA [$0A],Y             ; layout byte 1, first-group count
    STA $16
    STA $00
    LDA [$0A]
    SEC
    SBC $00                 ; layout byte 0 - byte 1
    REP #$20
    .a16
    AND #$00FF
    STA $04
    LDA $16
    AND #$00FF
    XBA
    AND #$FF00
    ORA $04
    STA $2BE6,X             ; $2BE7 first group, $2BE6 remainder

    ; Remaining sprite fields start unused or zero. $341A is left for upload.
    LDA #$FFFF
    STA $2D4E,X
    STA $2D12,X
    STA $2C9A,X
    STA $289E,X
    STZ $2BAA,X             ; fill-effect bits
    STZ $2DC6,X
    STZ $2D8A,X
    STZ $2C5E,X
    STZ $2B32,X
    STZ $2AF6,X             ; direction selector
    STZ $28DA,X
    LDA $02
returnEntity:
    PLD
    RTL
