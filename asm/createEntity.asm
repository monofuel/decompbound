; Create an entity and attach an action script, file $009321..$00943B
; (283 bytes). Exact end is the shared RTL at $C0943B; pause starts at
; $C0943C. That RTL is also the default far-callback body installed by
; $C09DA1 ($107A=$943B, $10B6=$00C0).
; JSL $C09321: native M16/X16, decimal clear, DBR=$7E. A=script selector,
; X/Y=initial coordinates. $0A4C is inclusive lower ID, $0A4E exclusive
; upper ID. Both are doubled in place to byte offsets before searching
; and are left doubled even on failure; callers must restore ID units
; before another call. Success returns A=raw entity ID with carry clear.
; Failure returns A=0 with carry set and consumes neither list. Entity
; ID 0 is a valid success: test carry, not A alone.
; JSL $C093B9: A=selector, X=existing entity offset. Returns the old
; state chain, allocates a new state, then shares the selector lookup.
; JSL $C093F9: X=entity ID, A=script pointer, Y=bank word. Doubles X and
; JSL $C09403. JSL $C09403: X=already-doubled offset, A=pointer, Y=bank.
; Inactive script IDs ($0A62 bit 15) halt with BRA * ; $C09403/$C093B9
; are JSL-only because they RTL through this shared tail.
; Template words $0A38..$0A46 copy into $0E5E..$1002; $0A48 into $0C06;
; $0A4A into queue-group $103E. Coordinates fill $0B8E/$0B16 and
; $0BCA/$0B52. Defaults: $121E=$9FC8, $11A6=$A023, $11E2=$A3A4.
; $0C42/$0C7E/$0CBA start at $8000 (meaning open). Frame $10F2=$FFFF
; so the graphics dispatcher rejects it until updated. $1372/$12E6 of
; the attached state are cleared. Selector A*3 indexes the three-byte
; pointer table at $C400D4; $13FE gets the word and $148A the bank byte.
; Allocated state next-link is $FFFF. Append uses $C09C57. Preserves D,
; DBR and stack depth. Tests: integration_entity_create,
; integration_entity_system.checkDefaultConstructor.
.a16
.i16
PHA
PHY
PHX
LDA $0A4C
ASL A
STA $0A4C
LDA $0A4E
ASL A
STA $0A4E
JSR $9C02
BCC entityAllocated
PLA
PLA
PLA
LDA #$0000
RTL
entityAllocated:
JSR $9D03
TYA
STA $0ADA,X
LDA #$FFFF
STA $125A,Y
LDA #$9FC8
STA $121E,X
LDA #$A023
STA $11A6,X
LDA #$A3A4
STA $11E2,X
LDA $0A38
STA $0E5E,X
LDA $0A3A
STA $0E9A,X
LDA $0A3C
STA $0ED6,X
LDA $0A3E
STA $0F12,X
LDA $0A40
STA $0F4E,X
LDA $0A42
STA $0F8A,X
LDA $0A44
STA $0FC6,X
LDA $0A46
STA $1002,X
LDA $0A4A
STA $103E,X
LDA #$8000
STA $0C42,X
STA $0C7E,X
STA $0CBA,X
PLA
STA $0B8E,X
STA $0B16,X
PLA
STA $0BCA,X
STA $0B52,X
LDA $0A48
STA $0C06,X
JSR $9C57
PLA
BRA attachScriptSelector
replaceAttachedScript:
PHA
JSR $9C99
JSR $9D03
TYA
STA $0ADA,X
LDA #$FFFF
STA $125A,Y
PLA
attachScriptSelector:
STA $0A62,X
PHX
ASL A
ADC $0A62,X
TXY
TAX
LDA $C400D6,X
TAY
LDA $C400D4,X
PLX
STZ $10F2,X
DEC $10F2,X
STZ $0DAA,X
STZ $0CF6,X
STZ $0DE6,X
STZ $0D32,X
STZ $0E22,X
STZ $0D6E,X
BRA installScriptPointer
replaceScriptById:
PHA
TXA
ASL A
TAX
PLA
JSL $C09403
RTL
replaceScriptByOffset:
PHY
PHA
LDA $0A62,X
BPL scriptEntityActive
inactiveEntityHalt:
BRA inactiveEntityHalt
scriptEntityActive:
JSR $9C99
JSR $9D03
TYA
STA $0ADA,X
LDA #$FFFF
STA $125A,Y
PLA
PLY
installScriptPointer:
PHY
PHA
JSR $9DA1
TXY
LDX $0ADA,Y
PLA
STA $13FE,X
PLA
AND #$00FF
STA $148A,X
STZ $1372,X
STZ $12E6,X
TYA
LSR A
CLC
RTL
