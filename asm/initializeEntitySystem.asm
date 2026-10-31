; Initialize entity and script-state pools, file $009282..$0092F4 (115 bytes).
; JSL $C09282: native M16/X16, decimal clear, DBR=$7E, PBR=$C0. RTL return.
; 30 entity slots (offsets $00..$3A) and 70 script-state slots ($00..$8A).
; List values are byte offsets; $FFFF terminates. Templates $0A38..$0A4A,
; bounds $0A4C/$0A4E, and callback $0A5E are left untouched. Preserves D,
; DBR and stack depth; A/X/Y and flags are scratch.
; Same-bank JSR $0000 requires this PBR; the $80 mirror would hit RAM.
; Evidence: docs/scripts.md.

    .a16
    .i16

initializeEntitySystem:
    ; Empty active list. Pre-terminate the last free-entity and free-state
    ; next links so the incrementing loops may start at the previous slot.
    LDX #$FFFF
    STX $0A50              ; Active-entity head.
    STX $0AD8              ; $0A9E+$3A, last entity next.
    STX $12E4              ; $125A+$8A, last script-state next.
    INX
    STX $0A52              ; Free-entity head, offset 0.
    STX $0A54              ; Free-state head, offset 0.

    ; Binary +2 links. Decimal clear is required; carry stays clear in-loop.
    CLC
    LDX #$0038             ; Slot 28, just before the pre-terminated last.
linkFreeEntities:
    TXA
    ADC #$0002
    STA $0A9E,X
    DEX
    DEX
    BPL linkFreeEntities

    LDX #$0088             ; Slot 68, just before the pre-terminated last.
linkFreeScriptStates:
    TXA
    ADC #$0002
    STA $125A,X
    DEX
    DEX
    BPL linkFreeScriptStates

    ; Negative script ID marks every slot inactive.
    LDX #$003A
    LDA #$FFFF
markEntitiesInactive:
    STA $0A62,X
    DEX
    DEX
    BPL markEntitiesInactive

    ; Graphics bank/state and far-callback bank / pause bits, all 30 slots.
    LDX #$003A
clearEntityBankWords:
    STZ $116A,X
    STZ $10B6,X
    DEX
    DEX
    BPL clearEntityBankWords

    ; Offsets 0, 2, 4, 6 only. $103E is the queue group.
    ; TODO: Explain the eight four-entry arrays at $1A02..$1A3A.
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

    JSR $0000              ; clearWramBlock280C: zero $7E:280C..2848.
    STZ $0A60              ; Scheduler lock.
    RTL
