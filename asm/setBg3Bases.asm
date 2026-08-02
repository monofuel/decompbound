; Adopted region setBg3Bases; ported from snes_src at M5. File offset 0x008E1C.
; origin file/SNES context: $008E1C
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
STA $0013
REP #$20
.a16
.i16
TXA
XBA
SEP #$20
.a8
.i16
AND #$FC
ORA $0013
STA $0013
STA $002109
LDA $0016
AND #$F0
STA $0016
REP #$20
.a16
.i16
STZ $0039
STZ $003B
TYA
XBA
SEP #$20
.a8
.i16
LSR A
LSR A
LSR A
LSR A
ORA $0016
STA $0016
STA $00210C
PLP
RTL
