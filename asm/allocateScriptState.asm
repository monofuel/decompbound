; Pop one script-state slot from the free list. File $009D03..$009D11
; (15 bytes). JSR entry $C09D03: native M16/X16, DBR=$7E. $0A54 is the
; free-state head. A negative head fails with Y=that head, carry set, and no
; writes; A is preserved. Success returns Y=allocated offset, $0A54 set
; to the old next link, carry clear. The allocated node's $125A next
; pointer is left stale; createEntity stores $FFFF there. Preserves X, D,
; DBR and stack depth. Test: integration_entity_system.checkStateAllocation.
.a16
.i16
LDY $0A54
BPL takeFreeScriptState
SEC
RTS
takeFreeScriptState:
LDA $125A,Y
STA $0A54
CLC
RTS
