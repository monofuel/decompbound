; Emit sprite elements into the current OAM build buffer.
; File $008CD5..$008D78; native JSL entry with decimal arithmetic clear.
; A is the definition address, byte $000B its bank, and X/Y the origin.
; Preserves processor status, DBR, direct page, and stack depth; clobbers A/X/Y.
; Direct page is temporarily zero. Scratch words $9B/$9D hold origin X/Y,
; and $9F holds the accepted screen Y. $03/$05 are low-table cursor/end.
; Long pointer $07 addresses the high table; $0A packs X-high and size bits
; around a sentinel initially $80. High-table cursor increments are byte-wide.
; Records contain signed Y, tile, attributes, signed X, and size/last flags.
; Y byte $80 redirects to the following word address in the same bank.
; Screen Y is origin + displacement - 1, accepted in -32..223; screen X
; is origin + displacement, accepted in -256..255, with 16-bit wrapping.
; X rejection leaves tile/attributes and low X written without advancing.
; Partial high-table groups remain pending; this routine does not flush them.
.a16
.i16
PHP
PHD
PEA $0000
PLD
REP #$30
STX $9B
STY $9D
TAY
LDX $03
CPX $05
BCC selectDefinitionBank
PLD
PLP
RTL
selectDefinitionBank:
PHB
SEP #$20
.a8
LDA $0B
PHA
PLB
BRA readElement
redirectDefinition:
.a16
LDA $0001,Y
TAY
BRA readElement
nextElement:
INY
INY
INY
INY
INY
readElement:
REP #$20
.a16
LDA $0000,Y
AND #$00FF
CMP #$0080
BCC addOriginY
BEQ redirectDefinition
ORA #$FF00
CLC
addOriginY:
ADC $9D
DEC A
CMP #$00E0
BCC writeTileAndCheckX
CMP #$FFE0
BCS writeTileAndCheckX
SEP #$20
rejectedElement:
.a8
LDA $0004,Y
BPL nextElement
BRA finishElements
writeTileAndCheckX:
.a16
STA $9F
LDA $0001,Y
STA $02,X
LDA $0003,Y
AND #$00FF
CMP #$0080
BCC addOriginX
ORA #$FF00
CLC
addOriginX:
ADC $9B
SEP #$20
.a8
STA $00,X
XBA
BEQ packHighBits
CMP #$FF
BNE rejectedElement
packHighBits:
ROL A
ROR $0A
LDA $0004,Y
ROR A
ROR $0A
BCC writeYAndAdvance
LDA $0A
STA [$07]
INC $07
LDA #$80
STA $0A
writeYAndAdvance:
LDA $9F
STA $01,X
INX
INX
INX
INX
LDA $0004,Y
BMI finishElements
REP #$20
.a16
CPX $05
BCC nextElement
finishElements:
STX $03
PLB
PLD
PLP
RTL
