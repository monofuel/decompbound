; Adopted region sramMirrorPiracyCheck; ported from snes_src at M5. File offset 0x00A11C.
; origin file/SNES context: $00A11C
.a16
.i16
SEP #$20
.a8
.i16
LDA #$30
STA $307FF0
INC A
STA $317FF0
CMP $307FF0
BEQ +12
REP #$20
.a16
.i16
PLA
TSC
SBC #$0100
TCD
JML $C30100
LDA $00213F
AND #$F010
TSB $20C2
PLA
TSC
SBC #$0100
TCD
JML $C30142
REP #$20
.a16
.i16
RTL
