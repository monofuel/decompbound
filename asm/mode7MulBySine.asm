; Adopted region mode7MulBySine; ported from snes_src at M5. File offset 0x00B400.
; origin file/SNES context: $00B400
.a16
.i16
PHA
TXA
SEC
SBC #$0040
AND #$00FF
TAX
PLA
SEP #$20
.a8
.i16
STA $00211B
XBA
STA $00211B
LDA $C0B425,X
STA $00211C
REP #$20
.a16
.i16
LDA $002135
RTL
