; Adopted region queueApuCommand; ported from snes_src at M5. File offset 0x00ABE0.
; origin file/SNES context: $00ABE0
.a16
.i16
SEP #$30
.a8
.i8
CMP #$00
BEQ +27
LDX $00CA
ORA $1ACA
STA $1AC2,X
TXA
INC A
AND #$07
STA $00CA
LDA #$80
EOR $1ACA
STA $1ACA
REP #$30
.a16
.i16
RTL
