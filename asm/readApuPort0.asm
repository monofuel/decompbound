; Adopted region readApuPort0; ported from snes_src at M5. File offset 0x00AC20.
; origin file/SNES context: $00AC20
.a16
.i16
SEP #$20
.a8
.i16
LDA $002140
REP #$30
.a16
.i16
AND #$00FF
RTL
