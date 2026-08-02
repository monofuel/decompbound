; Adopted region earthboundRandom; ported from snes_src at M5. File offset 0x008E9A.
; origin file/SNES context: $008E9A
.a16
.i16
PHP
REP #$20
.a16
.i16
LDA $0024
SEP #$20
.a8
.i16
XBA
LDA $0026
REP #$20
.a16
.i16
STA $004202
CLC
ADC #$006D
STA $0026
LDA $004216
ROR A
ROR A
PHA
AND #$0003
CLC
ADC $0024
ROR A
BCC +3
ORA #$8000
STA $0024
PLA
ROR A
ROR A
AND #$00FF
PLP
RTL
