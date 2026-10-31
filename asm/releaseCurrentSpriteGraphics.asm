; Release the current entity's sprite definition records and tile tags.
; File $0020F1..$00213F (79 bytes). Native JSL $C020F1, DBR=$7E, decimal clear.
; Reads the current entity ID from $1A42. Releases the runtime definition at
; $112E,Y through releaseSpriteDefinitions $C01B15, then replaceSpriteSlotTags
; $C01C11 with A=entity ID and X=0 to free matching occupancy bytes.
; If the original $2C9A top nibble is $8, 16-bit DEC $4A5C (wraps through zero
; to $FFFF). If $2D12 == $00E1, STZ $4A60. The meanings of those categories
; remain open. $2CD6 and $2C9A become $FFFF. The entity and its action-script
; state stay allocated. VRAM pixels are not cleared and no DMA occurs.
; Temporary direct page at caller D-$10: $02 entity ID, $0E entity byte offset.
; Preserves D, DBR and stack depth; A/X/Y and flags are scratch, A/X return
; 16-bit. Tests: tests/integration_sprite_spawn.nim native-call path of the
; synthetic action script (1,392 cases) via opcode $42 to $C020F1.
.a16
.i16
REP #$31
PHD
TDC
ADC #$FFF0
TCD
LDA $1A42
STA $02
ASL A
TAY
STY $0E
LDA $112E,Y
JSL $C01B15
LDX #$0000
LDA $02
JSL $C01C11
LDY $0E
LDA $2C9A,Y
AND #$F000
CMP #$8000
BNE skipCategoryDec
DEC $4A5C
skipCategoryDec:
LDA $02
ASL A
TAX
LDA $2D12,X
CMP #$00E1
BNE skipEffectClear
STZ $4A60
skipEffectClear:
LDA $02
ASL A
TAX
LDA #$FFFF
STA $2CD6,X
STA $2C9A,X
PLD
RTL
