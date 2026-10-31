; Select a resource graphics entry and transfer one normal sprite frame.
; File $00A4C4..$00A53E (123 bytes). Native JSL $C0A4C4, DBR=$7E, decimal clear.
; Y is the entity byte offset. Chunk count comes from $2ABA,Y into DP $00;
; bytes-per-chunk from $2A7E,Y into $0092; initial VRAM word from $298E,Y into
; $0097. $29CA,Y / $2A06,Y is the inline entry-list far pointer at DP $02/$04.
; Direction selector $2AF6,Y indexes the word table at $C0A60B (file $00A60B).
; Tested selectors are 0-7; no selector bounds check is established.
; entryAddress = list + 4 * table[direction] + 2 * (animationPhase != 0),
; where animationPhase is the global word $2892.
; Graphics-entry bit 1 ($0002) skips the optional leading-chunk fill.
; Otherwise $2BAA,Y bit 3 ($0008) enables one leading fill chunk and bit 2
; ($0004) enables a second. Fills use DMA profile 3 and the zero byte at
; $C40BE8 (file $040BE8) through transferSpriteChunk $C0A56E. Each fill
; consumes one chunk from the count without advancing the graphics source.
; If filling consumes the entire count, relative BEQ +63 / +48 land on the
; RTL at $C0A56D and the prior $341A word survives. Those branches target
; the next adopted file; their original displacements are kept numeric.
; Otherwise LDY $08 restores the entity offset and execution falls through
; into readSpriteGraphicsEntry at $C0A53F. The game meaning of the $2BAA
; effect bits remains open.
; Caller D must supply $00-$08. Preserves D, DBR and stack depth on the
; fall-through and early-RTL paths once transferSpriteChunk returns.
; Tests: tests/integration_sprite_dma.nim 4,864 full-upload cases.
.a16
.i16
STY $08
LDA $2ABA,Y
STA $00
LDA $2A7E,Y
STA $0092
LDA $298E,Y
STA $0097
LDA $2A06,Y
STA $04
LDA $29CA,Y
STA $02
LDA $2AF6,Y
ASL A
TAX
LDA $C0A60B,X
BEQ applyPhase
TAX
LDA $02
CLC
advanceDirection:
ADC #$0004
DEX
BNE advanceDirection
STA $02
applyPhase:
LDA $2892
BEQ checkFill
INC $02
INC $02
checkFill:
LDA [$02]
AND #$0002
BNE continueToEntry
LDA $2BAA,Y
STA $06
AND #$0008
BEQ continueToEntry
SEP #$20
.a8
LDA #$03
STA $0091
LDA #$C4
STA $0096
REP #$20
.a16
LDA #$0BE8
STA $0094
JSL $C0A56E
DEC $00
BEQ +63
LDA $06
AND #$0004
BEQ continueToEntry
JSL $C0A56E
DEC $00
BEQ +48
continueToEntry:
LDY $08
