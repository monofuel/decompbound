; Adopted region applyColorMathPreset; ported from snes_src at M5. File offset 0x00AFCD.
; origin file/SNES context: $00AFCD
.a16
.i16
TAX
SEP #$20
.a8
.i16
LDA $C0AFF1,X
STA $001A
LDA $C0AFFC,X
STA $001B
LDA $C0B006,X
STA $002130
LDA $C0B010,X
STA $002131
REP #$20
.a16
.i16
RTL
