; Adopted region resetWindowPositions; ported from snes_src at M5. File offset 0x00B0AA.
; origin file/SNES context: $00B0AA
.a16
.i16
REP #$20
.a16
.i16
LDA #$00FF
STA $002126
STA $002128
RTL
