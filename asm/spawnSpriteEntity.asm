; Create a sprite entity from a resource ID, script selector, and owner.
; File $001E49..$0020F0 (680 bytes). Native JSL $C01E49, DBR=$7E, decimal clear.
; A is resource ID, X is action-script selector, Y is owner request, and caller
; DP+$0E/+$10 hold X/Y coordinates. Direct page moves down $31 for private
; scratch; nested callees use additional space below that. Scratch must be
; disjoint from the entity arrays. On tested success paths it preserves caller
; D/DBR/stack and returns the entity ID in A.
; Owner $FFFF reserves temporary tile tags, asks the entity constructor for an
; available ID in 0..21 ($0A4C=0, $0A4E=$0016), then retags occupancy with the
; selected ID through replaceSpriteSlotTags $C01C11. A specific owner stores
; that exact ID in $0A4C/$0A4E and does not retag. Queue group $0A4A is set to 1.
; If $436C is nonzero and resource ID is $FFFF, the routine returns A=0 without
; allocating. The meaning of $436C is open.
; Tile allocation failure ($FF03) spins at $C01EB5. Definition-finder failure
; ($FF01/$FF02) spins at $C01EEF. These waits are intentional. The constructor
; $C09321 carry is not inspected; later entity-field stores use A as an ID even
; if construction failed.
; Resource pointer table $EF133F (file $2F133F). Layout pointer table $C42B0D
; (file $042B0D). Slot VRAM words $C42F8C. Layout-indexed word $C42AEB.
; Resource byte 3 is the builder attribute modifier. Bytes 4-7 populate
; $3366/$33A2/$33DE/$1A4A; their meanings remain open. Byte 8 is the graphics
; bank at $2A42. Address+9 is the inline graphics-entry list at $29CA/$2A06.
; Layout byte 0 is record count; byte 1 is the first priority-group count at
; $2BE7, with (byte0-byte1)&$FF at $2BE6. Odd resource height adds $100 to
; upload destination $298E.
; This wrapper does not upload a graphics frame or execute the attached script.
; $341A is left for later upload/update. Tests:
; tests/integration_sprite_spawn.nim (2,784 success-path cases).
.a16
.i16
REP #$31
PHD
PHA
TDC
ADC #$FFCF
TCD
PLA
STY $04
PHA
LDA $04
STA $2F
PLA
STX $2D
STA $2B
LDY $41
STY $29
LDX $3F
STX $27
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
STA $0C
LDA $2B
ASL A
ASL A
CLC
ADC $0A
STA $0A
LDY #$0002
LDA [$0A],Y
TAY
LDA [$0A]
STA $06
STY $08
LDA $06
STA $23
LDA $08
STA $25
LDA $2B
JSR $1DED
STA $02
LDY $04
LDX $467C
LDA $467A
JSL $C01C52
STA $21
waitForTileSlots:
LDA $21
CMP #$7FFF
BEQ lookupLayout
BCS waitForTileSlots
lookupLayout:
LDA #$2B0D
STA $06
LDA #$00C4
STA $08
LDA $02
ASL A
ASL A
CLC
ADC $06
STA $06
LDY #$0002
LDA [$06],Y
TAY
LDA [$06]
STA $0A
STY $0C
LDA [$0A]
AND #$00FF
STA $04
ASL A
ASL A
ADC $04
ASL A
JSL $C01A9D
STA $1F
waitForDefinitionSpace:
LDA $1F
CMP #$7FFF
BEQ prepareConstructor
BCS waitForDefinitionSpace
prepareConstructor:
LDA #$0001
STA $0A4A
LDA $0A
STA $06
LDA $0C
STA $08
LDA $06
STA $0E
LDA $08
STA $10
LDA $23
STA $06
LDA $25
STA $08
SEP #$20
.a8
LDY #$0003
LDA [$06],Y
REP #$20
.a16
AND #$00FF
TAY
LDX $21
LDA $1F
JSR $1D38
LDA $2F
STA $04
CMP #$FFFF
BEQ autoOwner
LDA $04
STA $0A4C
LDA $04
INC A
STA $0A4E
LDY $29
LDX $27
LDA $2D
JSL $C09321
STA $02
BRA attachDefinition
autoOwner:
STZ $0A4C
LDA #$0016
STA $0A4E
LDY $29
LDX $27
LDA $2D
JSL $C09321
STA $02
ORA #$0080
TAX
LDA #$FFFF
JSL $C01C11
attachDefinition:
LDA $02
ASL A
TAY
STY $1D
LDA $1F
CLC
ADC #$467E
STA $112E,Y
LDA #$007E
STA $116A,Y
LDA [$0A]
AND #$00FF
STA $04
ASL A
ASL A
ADC $04
STA $2916,Y
LDA $21
STA $2952,Y
TYA
CLC
ADC #$298E
TAX
STX $1B
LDA $21
ASL A
TAX
LDA $C42F8C,X
CLC
ADC #$4000
LDX $1B
STA $0000,X
SEP #$20
.a8
LDY #$0001
LDA [$06],Y
REP #$20
.a16
AND #$00FF
ASL A
LDY $1D
STA $2A7E,Y
LDA [$06]
AND #$00FF
STA $2ABA,Y
LDA $23
STA $06
LDA $25
STA $08
SEP #$20
.a8
LDY #$0008
LDA [$06],Y
REP #$20
.a16
AND #$00FF
LDY $1D
STA $2A42,Y
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
STA $14
LDA $2B
LDY $1D
STA $2CD6,Y
LDA $14
STA $2A06,Y
LDA $12
CLC
ADC #$0009
STA $29CA,Y
LDA $467C
AND #$0001
BEQ storeLayoutId
LDA $0000,X
CLC
ADC #$0100
STA $0000,X
storeLayoutId:
LDA $02
ASL A
TAX
STX $1B
LDA $23
STA $06
LDA $25
STA $08
INC $06
INC $06
LDA $06
STA $17
LDA $08
STA $19
LDA [$17]
AND #$00FF
STA $2B6E,X
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
LDA $C42AEB,X
LDX $1B
STA $332A,X
SEP #$20
.a8
LDY #$0001
LDA [$0A],Y
STA $16
STA $00
LDA [$0A]
SEC
SBC $00
REP #$20
.a16
AND #$00FF
STA $04
LDA $16
AND #$00FF
XBA
AND #$FF00
ORA $04
STA $2BE6,X
LDA #$FFFF
STA $2D4E,X
STA $2D12,X
STA $2C9A,X
STA $289E,X
STZ $2BAA,X
STZ $2DC6,X
STZ $2D8A,X
STZ $2C5E,X
STZ $2B32,X
STZ $2AF6,X
STZ $28DA,X
LDA $02
returnEntity:
PLD
RTL
