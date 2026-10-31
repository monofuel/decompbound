; Pop one script-state slot from the free list. File $009D03..$009D11
; (15 bytes). JSR $C09D03: native M16/X16, DBR=$7E. $0A54 is the free-state
; head. Negative head fails with Y=that head, carry set, A preserved.
; Success: Y=allocated offset, carry clear; $125A next is left stale.
; Preserves X, D, DBR and stack depth. Evidence: docs/scripts.md.

    .a16
    .i16

allocateScriptState:
    LDY $0A54              ; Free-state head; negative means empty.
    BPL takeFreeScriptState
    SEC
    RTS
takeFreeScriptState:
    LDA $125A,Y            ; Next link; left stale on the allocated node.
    STA $0A54
    CLC
    RTS
