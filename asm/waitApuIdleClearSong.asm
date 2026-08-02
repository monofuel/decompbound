; Adopted region waitApuIdleClearSong; ported from snes_src at M5. File offset 0x00ABC6.
; origin file/SNES context: $00ABC6
.a16
.i16
SEP #$20
.a8
.i16
LDA #$00
STA $002140
REP #$30
.a16
.i16
JSL $C0AC20
CMP #$0000
BNE -9
LDA #$FFFF
STA $B53B
RTL
