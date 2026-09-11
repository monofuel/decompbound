; Select the current entity's frame from one unsigned operand byte.
; File $0096CF..0096E2; RTS handler used by low opcodes $3B/$45 and $80..8F.
; Native M16/X16, WRAM DBR. DP+$88 is the entity byte offset; [$80],Y
; points to the operand. $FF maps to $FFFF (disabled frame); otherwise
; the byte is zero-extended into $10F2+entityOffset. Returns A=stored value,
; X=entityOffset, Y=oldY+1 (16-bit wrap). Preserves D/DBR and stack depth.
; Carry is set exactly for operand $FF; N/Z follow the final INY.
; Packed-opcode waits are installed by the fetch loop, not this handler.
.a16
.i16
LDX $88
LDA [$80],Y
AND #$00FF
CMP #$00FF
BNE storeFrame
LDA #$FFFF
storeFrame:
STA $10F2,X
INY
RTS
