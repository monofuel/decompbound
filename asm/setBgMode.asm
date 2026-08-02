; Adopted region setBgMode; ported from snes_src at M5. File offset 0x008D79.
; origin file/SNES context: $008D79
.a16
.i16
PHP
SEP #$20
.a8
.i16
XBA
LDA $000F
AND #$F0
STA $000F
XBA
ORA $000F
STA $000F
STA $002105
PLP
RTL
