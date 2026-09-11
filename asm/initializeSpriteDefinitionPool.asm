; Fill the 896-byte runtime sprite-definition pool with the free marker $FF.
; File $001A86..$001A9C. Native JSL entry, DBR=$7E.
; Preserves D, DBR, Y and stack depth; returns A/X 16-bit, X=$0380.
; The pool holds five-byte records; its final byte is not a complete record.
.a16
.i16
REP #$31
LDX #$0000
BRA checkPoolEnd
fillPoolByte:
SEP #$20
.a8
LDA #$FF
STA $467E,X
INX
checkPoolEnd:
CPX #$0380
BCC fillPoolByte
REP #$20
.a16
RTL
