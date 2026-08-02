; Adopted region clearHdmaEnableBit; ported from snes_src at M5. File offset 0x00AE34.
; origin file/SNES context: $00AE34
.a16
.i16
TAX
SEP #$20
.a8
.i16
LDA $001F
AND $C0AE44,X
STA $001F
REP #$20
.a16
.i16
RTL
