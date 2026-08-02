; Adopted region setBg1Bases; ported from snes_src at M5. File offset 0x008D9E.
; origin file/SNES context: $008D9E
.a16
.i16
PHP
SEP #$20
.a8
.i16
REP #$10
.a8
.i16
AND #$03
STA $0011
REP #$20
.a16
.i16
TXA
XBA
SEP #$20
.a8
.i16
AND #$FC
ORA $0011
STA $0011
STA $002107
LDA $0015
AND #$F0
STA $0015
REP #$20
.a16
.i16
STZ $0031
STZ $0033
TYA
XBA
SEP #$20
.a8
.i16
LSR A
LSR A
LSR A
LSR A
ORA $0015
STA $0015
STA $00210B
PLP
RTL
