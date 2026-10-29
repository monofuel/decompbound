; Packed-bit extraction and low-byte lookup for readWorldMapTile.asm.
; File $00A1CE..$00A1F1, SNES $C0A1CE; entries selected by row modulo 8.
; X=(row&7)*4 indexes both the padded near-pointer table and C42F64.
; Y=(row>>3)*256+column. A contains two packed high-bit source bytes.
; Entry A1CE shifts 6, A1D0 shifts 4, A1D2 shifts 2, A1D4 shifts 0 bits.
; Combine the selected two bits with the row-stream low byte, cache, restore D.
.a16
.i16
MapHighBitsShiftSix:
LSR A
LSR A
MapHighBitsShiftFour:
LSR A
LSR A
MapHighBitsShiftTwo:
LSR A
LSR A
MapHighBitsShiftZero:
AND #$0003
XBA
STA $08
LDA $C42F64,X
STA $04
LDA $C42F66,X
STA $06
LDA [$04],Y
AND #$00FF
ORA $08
STA $288C
PLD
RTS
