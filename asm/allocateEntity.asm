; Take the first free entity whose offset lies in [$0A4C, $0A4E).
; File $009C02..$009C34 (51 bytes). JSR entry $C09C02: native M16/X16,
; DBR=$7E. Bounds are already doubled byte offsets, not raw IDs;
; createEntity ASL-stores $0A4C/$0A4E before this call. $0A54 must be a
; non-negative script-state free head; a negative head fails without
; walking the entity list. $0A52 is the free-entity head. Y tracks the
; predecessor ($FFFF at the head). A candidate below $0A4C or not below
; $0A4E is skipped. Success unlinks X from the free list, leaves its
; $0A9E next pointer stale, returns X=offset with carry clear. Failure
; returns carry set without list writes; A/X/Y are scratch. Preserves D,
; DBR and stack depth. Lists must be valid and $FFFF-terminated.
; Tests: integration_entity_create (via $C09321), integration_entity_system.
.a16
.i16
LDA $0A54
BMI allocateEntityFailed
LDY #$FFFF
LDA $0A52
BMI allocateEntityFailed
scanFreeEntity:
TAX
CPX $0A4C
BCC skipOutOfRangeEntity
CPX $0A4E
BCC takeFreeEntity
skipOutOfRangeEntity:
TXY
LDA $0A9E,X
BPL scanFreeEntity
allocateEntityFailed:
SEC
RTS
takeFreeEntity:
TYA
BPL unlinkFreeEntityMiddle
LDA $0A9E,X
STA $0A52
CLC
RTS
unlinkFreeEntityMiddle:
LDA $0A9E,X
STA $0A9E,Y
CLC
RTS
