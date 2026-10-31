; Zero constructor templates and set the full entity-ID range, then fall
; through into createEntity at $C09321. File $0092F5..$009320 (44 bytes).
; JSL entry $C092F5: native M16/X16, decimal clear, DBR=$7E. A is the script selector;
; X/Y are the initial coordinates. There is no RTL here: success and
; failure return through createEntity. The saved selector is restored
; before the fall-through. $0A38..$0A46, $0A48, and $0A4A become 0.
; $0A4C/$0A4E become inclusive 0 and exclusive 30 in ID units; createEntity
; then doubles them in place to offset units 0 and $3C. Callers that need
; a narrower ID window must JSL $C09321 instead. Preserves D, DBR and
; stack depth aside from the inner constructor. Test:
; integration_entity_system.checkDefaultConstructor.
.a16
.i16
PHA
STZ $0A48
STZ $0A38
STZ $0A3A
STZ $0A3C
STZ $0A3E
STZ $0A40
STZ $0A42
STZ $0A44
STZ $0A46
STZ $0A4A
LDA #$0000
STA $0A4C
LDA #$001E
STA $0A4E
PLA
