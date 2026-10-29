; Read a ten-bit world-map arrangement ID from native 32-pixel coordinates.
; File $00A152..$00A1AD, SNES $C0A152; long entry calls near entry $C0A156.
; Native X/Y16 is required; A is forced to 16 bits. A=column, X=row, DBR=$7E.
; Decimal mode is clear, as in the original binary-coordinate callers.
; Streaming callers C00AC5/C00BDC bound columns to 256 and rows to 320.
; Negative coordinates return $FFFF. Nonnegative out-of-atlas input is unbounded.
; Cache: WRAM $2888 column, $288A row, $288C ID. Cache hits preserve X/Y.
; Cache misses clobber X/Y. DBR, original D and stack are preserved on all paths.
; Packed upper bits come from D75000/D78000, selected by row bit 2.
; Lower bytes use one of eight row-interleaved long pointers at C42F64.
; The computed JMP uses jmpTableA1AE and readWorldMapTileTail.asm.
.a16
.i16
JSR ReadWorldMapTileNear
RTL
ReadWorldMapTileNear:
REP #$20
PHD
PHA
TDC
SEC
SBC #$000A
TCD
PLA
STA $00
STX $02
ORA $02
BPL NonnegativeMapCoordinates
LDA #$FFFF
PLD
RTS
NonnegativeMapCoordinates:
LDA $00
CMP $2888
BNE UncachedMapCoordinates
CPX $288A
BNE UncachedMapCoordinates
LDA $288C
PLD
RTS
UncachedMapCoordinates:
STA $2888
STX $288A
TXA
LSR A
LSR A
LSR A
XBA
ORA $00
TAY
LDA #$00D7
STA $06
LDX #$5000
LDA $02
AND #$0004
BEQ MapHighBitsBankSelected
LDX #$8000
MapHighBitsBankSelected:
STX $04
LDA $02
AND #$0007
ASL A
ASL A
TAX
LDA [$04],Y
JMP ($A1AE,X)
