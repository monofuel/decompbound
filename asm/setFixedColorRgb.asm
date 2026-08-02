; Adopted region setFixedColorRgb; ported from snes_src at M5. File offset 0x00B01A.
; origin file/SNES context: $00B01A
.a16
.i16
SEP #$20
.a8
.i16
AND #$1F
ORA #$20
STA $002132
TXA
AND #$1F
ORA #$40
STA $002132
TYA
AND #$1F
ORA #$80
STA $002132
REP #$20
.a16
.i16
RTL
