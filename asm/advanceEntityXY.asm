; Advance the current entity's world X/Y by its 32-bit steps.
; File $009FC8..$009FF0 (41 bytes). JSR $C09FC8: native M16/X16, decimal
; clear, DBR=$7E. DP+$88 is the entity byte offset; X is reloaded from it.
; Each axis is unsigned (integer << 16 | fraction) plus matching
; (intStep << 16 | fracStep). CLC starts the axis; the fraction ADC carry
; feeds the integer ADC. Constructor seeds fractions at $8000.
; Default $121E callback; pause bit 14 skips it. Preserves Y, D, DBR and
; stack depth; A/X and flags are scratch. Evidence: docs/scripts.md.

    .a16
    .i16

advanceEntityXY:
    LDX $88                 ; Scheduler entity offset.

    ; X: fraction first so its carry becomes the integer add's incoming C.
    LDA $0C42,X             ; X fraction.
    CLC
    ADC $0DAA,X             ; X fraction step.
    STA $0C42,X
    LDA $0B8E,X             ; World X integer.
    ADC $0CF6,X             ; X integer step plus fraction carry.
    STA $0B8E,X

    ; Independent 32-bit Y add; a fresh CLC drops leftover X carry.
    LDA $0C7E,X             ; Y fraction.
    CLC
    ADC $0DE6,X             ; Y fraction step.
    STA $0C7E,X
    LDA $0BCA,X             ; World Y integer.
    ADC $0D32,X             ; Y integer step plus fraction carry.
    STA $0BCA,X
    RTS
