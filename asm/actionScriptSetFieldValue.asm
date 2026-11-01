; Write an immediate word to one of eight indexed entity-template fields.
; File $009AE2..$009AF8 (23 bytes), SNES $C09AE2; JSR/RTS opcode $0E.
; Native M16/X16, decimal clear, WRAM DBR; DP+$88 is entity byte offset.
; [$80],Y operands: field byte and immediate word (three bytes); not a read
; into $1516. Returns X=field base+entityOffset, A=immediate, Y+=3 (wrap).
; Preserves D/DBR/widths, DP scratch and stream base/bank; N/Z follow final
; cursor increment; C/V follow address ADC. Field index is unchecked.
; Evidence: docs/scripts.md (entity templates and action VM dispatch).
    .a16
    .i16

actionScriptSetFieldValue:
    LDA [$80],Y
    AND #$00FF
    ASL A                  ; Field byte -> word-table offset; always clears C.
    TAX
    LDA $C09AF9,X
    ADC $88                ; No CLC needed: table load preserves ASL's C=0.
    TAX
    INY
    LDA [$80],Y            ; Long indexed word read may cross a bank boundary.
    STA $0000,X            ; Store in DBR, not the script stream's bank.
    INY
    INY                    ; Cursor wrap does not update DP+$82.
    RTS
