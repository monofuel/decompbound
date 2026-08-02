; Adopted region setBg4Bases; ported from snes_src at M5. File offset 0x008E5C.
; origin file/SNES context: $008E5C
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
STA $0014
REP #$20
.a16
.i16
TXA
XBA
SEP #$20
.a8
.i16
AND #$FC
ORA $0014
STA $0014
STA $00210A
LDA $0016
AND #$0F
STA $0016
REP #$20
.a16
.i16
STZ $003D
STZ $003F
TYA
XBA
SEP #$20
.a8
.i16
AND #$F0
ORA $0016
STA $0016
STA $00210C
PLP
RTL
