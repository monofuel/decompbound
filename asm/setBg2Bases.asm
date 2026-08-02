; Adopted region setBg2Bases; ported from snes_src at M5. File offset 0x008DDE.
; origin file/SNES context: $008DDE
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
STA $0012
REP #$20
.a16
.i16
TXA
XBA
SEP #$20
.a8
.i16
AND #$FC
ORA $0012
STA $0012
STA $002108
LDA $0015
AND #$0F
STA $0015
REP #$20
.a16
.i16
STZ $0035
STZ $0037
TYA
XBA
SEP #$20
.a8
.i16
AND #$F0
ORA $0015
STA $0015
STA $00210B
PLP
RTL
