; Enqueue the selected frame definition for the current entity.
; File $00A0FA..$00A11A, SNES $C0A0FA; 33 bytes. Entered by JMP from
; dispatchEntityGraphics when $11E2,X is $A0FA. Native M16/X16; DBR=$7E.
; A is the frame index from $10F2,X, already proven nonnegative. X is the
; entity byte offset. Doubles A into Y and reads a 16-bit definition pointer
; through long pointer DP $8C, whose bank byte DP $8E was installed by
; dispatch. Copies that bank byte to $000B, preserving neighboring $000C.
; Stores the pointer at DP $96, writes entity queue group $103E,X to $2400,
; loads origin Y from $0BCA,X and origin X from $0B8E,X, then JMP $8C58
; (enqueueOamDefinition near entry). The queue handler RTS returns to the
; original dispatch caller. Tile/attribute bytes come from the five-byte
; definition records, unchanged. Frame $4000..$7FFF indexes the upper half
; of the table's bank; these large tables are outside the tested inputs.
; Tests: integration_entity_sprite.nim, integration_action_script_fetch.nim.
.a16
.i16
ASL A
TAY
SEP #$20
.a8
LDA $8E
STA $000B
REP #$20
.a16
LDA [$8C],Y
STA $96
LDA $103E,X
STA $2400
LDY $0BCA,X
LDA $0B8E,X
TAX
LDA $96
JMP $8C58
