; Reserve the first contiguous free run of 16x16 sprite tile slots.
; File $001B96..$001C10. Native JSL entry, DBR=$7E, decimal mode clear.
; A is the requested slot count (1..88); X supplies the owner tag's low byte.
; Occupancy is 88 bytes at $4A00. Zero means free; reservations store owner|$80.
; Returns A=starting slot or $FF03 if no run fits. Preserves D, DBR and stack
; depth; forces M/X16 and clobbers X/Y and arithmetic flags. No DMA occurs.
; Temporary direct page at caller D-$14 holds requested count ($12), owner
; ($04), scan offset ($10), mark offset ($0E), and arithmetic scratch ($02).
; Each occupancy read is a word masked to its low byte: the final slot's read
; also touches $4A58. Callers must provide accessible memory there.
; Zero count returns slot 0 without marking. Counts above 88 are unsupported:
; the unsigned search-limit subtraction wraps rather than rejecting them.
.a16
.i16
REP #$31
PHD
PHA
TDC
ADC #$FFEC
TCD
PLA
STX $04
STA $02
STA $12
LDY #$0000
BRA checkCandidate
scanCandidate:
LDA #$0000
STA $10
BRA checkScanCount
scanSlot:
STA $02
TYA
CLC
ADC $02
TAX
LDA $4A00,X
AND #$00FF
BNE skipOccupied
LDA $10
INC A
STA $10
checkScanCount:
LDX $12
STX $02
CMP $02
BCC scanSlot
LDA #$0000
STA $0E
BRA checkMarkCount
markSlot:
STA $02
TYA
CLC
ADC $02
TAX
LDA $04
SEP #$20
.a8
ORA #$80
STA $4A00,X
REP #$20
.a16
LDA $0E
INC A
STA $0E
checkMarkCount:
LDX $12
STX $02
CMP $02
BCC markSlot
TYA
BRA finish
skipOccupied:
TXY
INY
checkCandidate:
LDA $12
STA $02
LDA #$0058
SEC
SBC $02
STA $02
TYA
CMP $02
BCC scanCandidate
BEQ scanCandidate
LDA #$FF03
finish:
PLD
RTL
