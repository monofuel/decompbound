; Release sprite graphics for an explicit entity ID, then remove the entity.
; File $002140..$002193 (84 bytes). Native JSL $C02140, DBR=$7E, decimal clear.
; A is the entity ID. Graphics cleanup matches releaseCurrentSpriteGraphics:
; releaseSpriteDefinitions $C01B15, replaceSpriteSlotTags $C01C11 with X=0,
; optional DEC $4A5C when $2C9A top nibble is $8, optional STZ $4A60 when
; $2D12 == $00E1, and $2CD6/$2C9A := $FFFF. Meanings of those categories remain
; open. Then JSL removeEntityById $C09C35 at $C0218E, which unlinks the entity
; and returns its script-state chain to the free list.
; VRAM is not cleared and no DMA occurs. Temporary direct page at caller D-$10:
; $02 entity ID, $0E entity byte offset. Preserves D, DBR and stack depth;
; A/X/Y and flags are scratch. Tests: tests/integration_sprite_spawn.nim
; explicit-ID cleanup (1,392 cases). Single-entity, single script-state node
; is the supported check; middle-list removal is unverified here.
.a16
.i16
REP #$31
PHD
PHA
TDC
ADC #$FFF0
TCD
PLA
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
LDA $02
JSL $C09C35
PLD
RTL
