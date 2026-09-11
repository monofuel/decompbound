; Replace matching sprite-slot occupancy bytes, optionally selecting every slot.
; File $001C11..$001C51. Native JSL entry, DBR=$7E, decimal mode clear.
; A selects (low byte | $80), except exactly $8000 selects all 88 slots.
; X supplies the replacement low byte verbatim: zero frees the selected slots.
; Other replacements need not have bit 7 set. Unselected bytes are untouched.
; Temporary direct page at caller D-$10 holds selector ($0E) and match byte ($02).
; Word reads are masked to one byte, including the read across $4A57/$4A58.
; Returns M/X16, X=88, Y=entry X. A and arithmetic flags are scratch.
; Preserves D, DBR and stack depth. No graphics bytes are cleared or transferred.
.a16
.i16
REP #$31
PHD
PHA
TDC
ADC #$FFF0
TCD
PLA
TXY
STA $0E
LDX #$0000
BRA checkSlot
visitSlot:
REP #$20
LDA $0E
REP #$20
AND #$00FF
ORA #$0080
STA $02
LDA $4A00,X
AND #$00FF
CMP $02
BEQ replaceSlot
LDA $0E
CMP #$8000
BNE nextSlot
replaceSlot:
TYA
SEP #$20
.a8
STA $4A00,X
nextSlot:
INX
checkSlot:
CPX #$0058
BCC visitSlot
REP #$20
.a16
PLD
RTL
