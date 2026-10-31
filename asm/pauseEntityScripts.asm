; Set both scheduler pause bits on every active entity.
; File $00943C..$009450 (21 bytes). JSL entry $C0943C: native M16/X16,
; DBR=$7E. Walks $0A50 via next links $0A9E,X. ORA #$C000 sets $10B6
; bits 14 and 15; the low bank byte is preserved. Bit 14 skips script
; ticks and callback $121E; bit 15 skips far callback $107A. Callback
; $11A6 still runs. An empty (negative) head returns immediately.
; Preserves Y/D/DBR and stack depth; A/X and flags are scratch. Inactive
; entities are not visited. Test: integration_entity_system.checkPause.
.a16
.i16
LDX $0A50
BMI pauseScriptsDone
pauseActiveEntity:
LDA $10B6,X
ORA #$C000
STA $10B6,X
LDA $0A9E,X
TAX
BPL pauseActiveEntity
pauseScriptsDone:
RTL
