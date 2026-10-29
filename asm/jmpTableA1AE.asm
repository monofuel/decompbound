; World-map packed high-bit extraction dispatch, file $00A1AE, SNES $C0A1AE.
; C0A1A3 masks row&7; two ASLs produce X=rowModuloEight*4.
; JMP ($A1AE,X) selects a near entry in readWorldMapTileTail.asm.
; Each entry is a near code pointer and a zero padding word. Padding is
; retained as original layout, not interpreted as part of the near pointer.
; Rows 0..3 read the D75000 plane, rows 4..7 the D78000 plane.
.word $A1D4, $0000 ; Row 0: preserve packed bits 0..1.
.word $A1D2, $0000 ; Row 1: shift packed bits 2..3 down by 2.
.word $A1D0, $0000 ; Row 2: shift packed bits 4..5 down by 4.
.word $A1CE, $0000 ; Row 3: shift packed bits 6..7 down by 6.
.word $A1D4, $0000 ; Row 4: preserve packed bits 0..1.
.word $A1D2, $0000 ; Row 5: shift packed bits 2..3 down by 2.
.word $A1D0, $0000 ; Row 6: shift packed bits 4..5 down by 4.
.word $A1CE, $0000 ; Row 7: shift packed bits 6..7 down by 6.
