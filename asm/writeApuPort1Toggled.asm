; Adopted region writeApuPort1Toggled; ported from snes_src at M5. File offset 0x00AC0C.
; origin file/SNES context: $00AC0C
.a16
.i16
SEP #$20
.a8
.i16
ORA $1ACB
STA $002141
LDA #$80
EOR $1ACB
STA $1ACB
REP #$30
.a16
.i16
RTL
