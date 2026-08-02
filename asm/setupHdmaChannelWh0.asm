; Adopted region setupHdmaChannelWh0; ported from snes_src at M5. File offset 0x00B0B8.
; origin file/SNES context: $00B0B8
.a16
.i16
TAY
ASL A
ASL A
ASL A
ASL A
TAX
SEP #$20
.a8
.i16
LDA $10
STA $004304,X
STA $004307,X
LDA #$26
STA $004301,X
LDA [$0E]
STA $004300,X
REP #$20
.a16
.i16
LDA $0E
INC A
STA $004302,X
SEP #$20
.a8
.i16
TYX
LDA $001F
ORA $C0AE16,X
STA $001F
REP #$20
.a16
.i16
RTL
