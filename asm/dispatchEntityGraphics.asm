; Load an entity's frame table and jump to its graphics callback.
; File $00A0E3..$00A0F9, SNES $C0A0E3. JSR, native M16/X16, DBR=$7E.
; Execute through PBR=$80 (or $00): the indirect callback table is WRAM.
; X is the entity byte offset. Taken path is JMP ($11E2,X): the callback
; RTS returns to this routine's caller. A holds the frame from $10F2,X.
; Rejections preserve D, DBR, and stack depth; A is clobbered.
; Evidence: docs/graphics.md (entity frame tables).
    .a16
    .i16

dispatchEntityGraphics:
    ; LDA sets N/Z from the bank/state word and does not update V, so BVS
    ; tests overflow inherited from the caller, not bank/state bit 14.
    LDA $116A,X             ; Bank/state word.
    BMI skipGraphics
    BVS skipGraphics
    STA $8E                 ; 16-bit: $8F receives neighboring $116B.
    LDA $112E,X
    STA $8C                 ; Frame-table address.

    LDA $10F2,X             ; Frame index; $FFFF is the disabled frame.
    BMI skipGraphics        ; After the DP stores; callback is skipped.
    JMP ($11E2,X)           ; Callback, not a nested JSR.
skipGraphics:
    ; Bank/V rejects leave $8C/$8E untouched; a negative frame does not.
    RTS
