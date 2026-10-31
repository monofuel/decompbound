; Clear both scheduler pause bits on every active entity.
; File $009451..$009465 (21 bytes). JSL entry $C09451: native M16/X16,
; DBR=$7E. Walks $0A50 via next links $0A9E,X. AND #$3FFF clears $10B6
; bits 14 and 15; the low bank byte is preserved. An unpaused entity
; must already have a valid script-state chain: the scheduler does not
; check for a negative $0ADA head. An empty (negative) head returns
; immediately. Preserves Y/D/DBR and stack depth; A/X and flags are
; scratch. Test: integration_entity_system.checkPause.
.a16
.i16
LDX $0A50
BMI resumeScriptsDone
resumeActiveEntity:
LDA $10B6,X
AND #$3FFF
STA $10B6,X
LDA $0A9E,X
TAX
BPL resumeActiveEntity
resumeScriptsDone:
RTL
