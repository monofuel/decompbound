; Width-polymorphic action-script operations, file $009AC5..$009AE1 (29 bytes).
; $009AC5 AND entry: JSR/RTS or tail JMP/RTS, native, M8 or M16, valid D.
; DP+$8C is a 16-bit target pointer into DBR; DP+$90 holds the immediate.
; Changes exactly one byte/word according to M; A receives the same result.
; Preserves D/DBR/X/Y/widths and stack depth; AND/OR/XOR set N/Z and preserve
; C/V. ADD clears C then sets N/Z/C/V; decimal clear required for binary sum.
; Wrappers clear C via selector ASL before dispatch, so their logical cases
; return C=0. In M8, accumulator high byte is preserved. See docs/scripts.md.
    .a16
    .i16

actionScriptAnd:
    LDA ($8C)
    AND $90
    STA ($8C)
    RTS

; $009ACC OR entry: same byte/word target and status contract as AND.
actionScriptOr:
    LDA ($8C)
    ORA $90
    STA ($8C)
    RTS

; $009AD3 ADD entry: same target/widths; discards incoming carry explicitly.
actionScriptAdd:
    LDA ($8C)
    CLC
    ADC $90                ; M8 wraps at 256; M16 wraps at 65536.
    STA ($8C)
    RTS

; $009ADB XOR entry: same byte/word target and status contract as AND.
actionScriptXor:
    LDA ($8C)
    EOR $90
    STA ($8C)
    RTS
