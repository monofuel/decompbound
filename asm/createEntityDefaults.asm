; Zero constructor templates and set the full entity-ID range, then fall
; through into createEntity at $C09321. File $0092F5..$009320 (44 bytes).
; JSL $C092F5: native M16/X16, decimal clear, DBR=$7E. A is the script
; selector; X/Y are the initial coordinates. No RTL: both outcomes return
; through createEntity. Narrower ID windows must JSL $C09321 instead.
; Preserves D, DBR and stack depth. Evidence: docs/scripts.md.

    .a16
    .i16

createEntityDefaults:
    PHA                    ; Selector is restored before the fall-through.

    ; Templates $0A38..$0A46, $0A48, and queue-group $0A4A.
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

    ; Inclusive 0 and exclusive 30 in ID units. createEntity doubles these
    ; in place to offset units 0 and $3C, including on failure.
    LDA #$0000
    STA $0A4C
    LDA #$001E
    STA $0A4E
    PLA
    ; Fall through into createEntity at $C09321.
