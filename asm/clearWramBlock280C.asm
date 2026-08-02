; Adopted region clearWramBlock280C; ported from snes_src at M5. File offset 0x000000.
; origin file/SNES context: $000000
.a16
.i16
STZ $280C
LDX #$280C
LDY #$280D
LDA #$003B
MVN $7E,$7E
LDA #$280C
RTS
