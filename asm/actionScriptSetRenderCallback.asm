; Install an entity graphics callback from opcode $22.
; File $009BE4..$009BED, SNES $C09BE4; 10 bytes. RTS handler, native M16/X16.
; Dispatch table $C09558 entry $22 points here. Y is already at the operands
; of long stream pointer DP $80; DP $88 is the entity byte offset (index*2).
; Operand is a 16-bit callback address stored at $11E2,X. Advances Y by two
; (16-bit wrap). Returns A=callback, X=entityOffset. Preserves D, DBR, and
; stack depth. N/Z follow the final INY. $A0FA is the table-index callback;
; other callbacks including default $A3A4 are outside this adoption.
; Tests: integration_entity_sprite.nim, integration_action_script_fetch.nim.
.a16
.i16
LDA [$80],Y
LDX $88
STA $11E2,X
INY
INY
RTS
