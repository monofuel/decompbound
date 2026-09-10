; Construct two consecutive runtime sprite-definition variants.
; File $001D38..$001DEC; native JSR entry, DBR=$7E, decimal arithmetic clear.
; A is the allocation offset from $467E, X the tile-allocation slot, and Y
; contributes its low byte to each OAM attribute. Caller DP+$0E is a layout
; far pointer. Its header byte 0 counts records per variant; byte 1 is ignored.
; Each five-byte source record supplies Y displacement, ignored tile byte,
; attributes, X displacement, and size/last flags. The tile word comes from
; $C4303C + 2*(allocation slot + record index), resetting for each variant.
; Output attributes are (source attributes & $FE) | resource attributes |
; tile-word high byte. Other copied fields retain their source representation.
; Source advances through both variants; low-word pointer increments do not
; advance the bank. Output uses $467E,X and advances ten bytes per header count.
; Scratch occupies a temporary direct page at caller D-$1A: $04 allocation
; slot, $06 far source cursor, $0E tile word, $10 output cursor, $12 record
; index, $14 variant index, $16 record count, $18 resource attributes.
; $00/$01 combine attribute bytes and $02 is arithmetic scratch.
; Returns M/X16, A=count, Y=2, X=initial output offset+10*count (16-bit).
; Preserves DBR, caller direct page, and stack depth; arithmetic flags change.
.a16
.i16
REP #$31
PHD
PHA
TDC
ADC #$FFE6
TCD
PLA
STY $18
STX $04
TAX
LDA $28
STA $06
LDA $2A
STA $08
LDA [$06]
AND #$00FF
STA $02
STA $16
INC $06
INC $06
LDY #$0000
STY $14
JMP checkVariantCount
beginVariant:
LDA #$0000
STA $12
BRA checkRecordCount
copyRecord:
SEP #$20
.a8
LDA [$06]
STA $467E,X
INX
STX $10
REP #$20
.a16
LDA $12
STA $02
LDA $04
CLC
ADC $02
ASL A
TAX
LDA $C4303C,X
STA $0E
SEP #$20
.a8
LDX $10
STA $467E,X
INX
REP #$20
.a16
LDA $0E
XBA
AND #$00FF
SEP #$20
.a8
STA $00
REP #$20
.a16
LDA $18
SEP #$20
.a8
STA $01
LDY #$0002
LDA [$06],Y
AND #$FE
ORA $01
ORA $00
STA $467E,X
INX
LDY #$0003
LDA [$06],Y
STA $467E,X
INX
LDY #$0004
LDA [$06],Y
STA $467E,X
INX
REP #$20
.a16
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
