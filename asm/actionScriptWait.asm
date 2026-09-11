; Set the current script state's wait from one unsigned operand byte.
; File $0096C3..0096CE; RTS handler for opcode $06.
; Native M16/X16, WRAM DBR. DP+$8A is the state byte offset; [$80],Y
; points to the operand. Sets $1372+stateOffset, returns X=stateOffset,
; A=operand, Y=oldY+1 (16-bit wrap). Preserves D/DBR and stack depth.
; The enclosing fetch loop decrements a nonzero wait in this same tick;
; zero continues dispatch immediately. N/Z follow the final INY; other status bits are preserved.
.a16
.i16
LDX $8A
LDA [$80],Y
AND #$00FF
STA $1372,X
INY
RTS
