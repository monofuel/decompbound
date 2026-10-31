; Install an entity frame-table pointer from opcode $1C.
; File $009B4D..$009B60, SNES $C09B4D; 20 bytes. RTS handler, native M16/X16.
; Dispatch table $C09558 entry $1C points here. Y is already at the operands
; of long stream pointer DP $80; DP $88 is the entity byte offset (index*2).
; Operand is a 16-bit table address plus an 8-bit bank. Stores the address at
; $112E,X and the bank byte at $116A,X; the neighboring high state byte at
; $116B,X is preserved by the 8-bit store. Advances Y by three (16-bit wrap).
; Returns A.low=bank byte, A.high=address high byte, X=entityOffset.
; Preserves D, DBR, and stack depth.
; N/Z follow the final INY. Used with $A0FA as a frame-index table bank.
; Tests: integration_entity_sprite.nim, integration_action_script_fetch.nim.
.a16
.i16
LDX $88
LDA [$80],Y
STA $112E,X
INY
INY
SEP #$20
.a8
LDA [$80],Y
STA $116A,X
REP #$20
.a16
INY
RTS
