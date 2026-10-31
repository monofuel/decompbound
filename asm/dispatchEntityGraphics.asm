; Load an entity's frame table and jump to its graphics callback.
; File $00A0E3..$00A0F9, SNES $C0A0E3; 23 bytes. JSR entry, native M16/X16.
; X is the entity byte offset. LDA $116A,X sets N/Z and does not update V.
; BMI rejects a negative bank/state word. BVS then rejects inherited overflow
; from the caller; it is not a test of bank/state bit 14. Both rejections
; leave DP $8C/$8E untouched and do not enter the callback.
; A nonnegative bank/state with V clear is stored at DP $8E (16-bit, so $8F
; receives $116B), then table word $112E,X is stored at DP $8C.
; LDA $10F2,X is the callback's A input. BMI rejects a negative frame after
; those DP stores and still skips the callback. $FFFF is the disabled frame
; written by opcode $3B/$45/$80..$8F on operand $FF.
; The taken path is JMP ($11E2,X), not JSR: the callback's RTS returns to
; this routine's caller. A holds the frame, X the entity offset, Y unchanged.
; Clobbers A. Preserves D, DBR, and stack depth on every rejection.
; Tests: integration_entity_sprite.nim (accepted path),
; integration_entity_system.nim checkGraphicsDispatch (every reject),
; integration_action_script_fetch.nim (script-installed $A0FA).
.a16
.i16
LDA $116A,X
BMI skipGraphics
BVS skipGraphics
STA $8E
LDA $112E,X
STA $8C
LDA $10F2,X
BMI skipGraphics
JMP ($11E2,X)
skipGraphics:
RTS
