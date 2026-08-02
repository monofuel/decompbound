; Adopted region hardwareMultiply; ported from snes_src at M5. File offset 0x008FF7.
; origin file/SNES context: $008FF7
.a16
.i16
REP #$10
.a16
.i16
XBA
BEQ +38
SEP #$20
.a8
.i16
XBA
PHA
TYA
REP #$20
.a16
.i16
STA $004202
NOP
NOP
LDA $004216
TAY
SEP #$20
.a8
.i16
PLA
STA $004203
REP #$20
.a16
.i16
TYA
XBA
AND #$FF00
CLC
ADC $004216
RTL
SEP #$20
.a8
.i16
TYA
REP #$20
.a16
.i16
STA $004202
NOP
NOP
LDA $004216
RTL
