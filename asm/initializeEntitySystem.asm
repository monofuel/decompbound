; Initialize entity and script-state pools, file $009282..$0092F4 (115 bytes).
; JSL entry $C09282: native M16/X16, decimal clear, DBR=$7E, PBR=$C0.
; Same-bank JSR $0000 reaches clearWramBlock280C at $C00000; the $80 mirror
; would instead JSR into bank $80 RAM. Preserves D, DBR and stack depth.
; A/X/Y and flags are scratch. Carry is cleared before the link loops.
; Builds 30 entity slots (offsets $00..$3A) and 70 script-state slots
; (offsets $00..$8A). List values are byte offsets; $FFFF terminates.
; $0A50 is the empty active head. $0A52/$0A54 are free heads at offset 0.
; The last-entity next link is $0A9E+$3A = $0AD8; last-state next is
; $125A+$8A = $12E4. Both are written $FFFF before the incrementing loops
; so the loops may start at the previous slot. Every entity script ID at
; $0A62 is $FFFF (inactive). $10B6 (far-callback bank / pause bits) and
; $116A (graphics bank/state) are zeroed for all 30 slots. Four low
; offsets 0,2,4,6 clear $103E queue-group words and eight $1Axx arrays.
; Meanings of $1A02..$1A3A remain open. Scheduler lock $0A60 is cleared.
; Templates $0A38..$0A4A, bounds $0A4C/$0A4E, and callback $0A5E are left
; untouched. Tests: integration_entity_system, integration_sprite_spawn.
.a16
.i16
LDX #$FFFF
STX $0A50
STX $0AD8
STX $12E4
INX
STX $0A52
STX $0A54
CLC
LDX #$0038
linkFreeEntities:
TXA
ADC #$0002
STA $0A9E,X
DEX
DEX
BPL linkFreeEntities
LDX #$0088
linkFreeScriptStates:
TXA
ADC #$0002
STA $125A,X
DEX
DEX
BPL linkFreeScriptStates
LDX #$003A
LDA #$FFFF
markEntitiesInactive:
STA $0A62,X
DEX
DEX
BPL markEntitiesInactive
LDX #$003A
clearEntityBankWords:
STZ $116A,X
STZ $10B6,X
DEX
DEX
BPL clearEntityBankWords
LDX #$0006
clearLowSlotScratch:
STZ $1A12,X
STZ $1A1A,X
STZ $1A22,X
STZ $1A32,X
STZ $1A2A,X
STZ $1A3A,X
STZ $1A02,X
STZ $1A0A,X
STZ $103E,X
DEX
DEX
BPL clearLowSlotScratch
JSR $0000
STZ $0A60
RTL
