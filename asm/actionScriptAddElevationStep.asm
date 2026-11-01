; actionScriptAddElevationStep — add to the entity's elevation motion step.
; File $0097B7..0097DB; SNES $C097B7..C097DB.
; JSR/RTS, native M16/X16, WRAM DBR; DP+$88 is the entity byte offset.
; [$80],Y supplies a signed little-endian 8.8 operand; DP+$90 saves it.
; Decimal clear required for binary ADC; incoming carry is ignored.
; Adds modulo 2^32 to the split 16.16 step at $0D6E/$0E22,X.
; Returns X=entity offset, Y+=2 modulo 65536; stream pointer/bank unchanged.
; A=result integer word; N/Z/C/V reflect final integer ADC.
; Preserves D, DBR and register widths. See docs/scripts.md for dispatch evidence.

    .a16
    .i16
actionScriptAddElevationStep:
    ; Long indexed reads can cross banks; cursor wrap does not update DP+$82.
    LDX $88
    LDA [$80],Y
    INY
    INY
    STA $90

    ; The operand's fractional byte becomes bits 8..15 of the 16-bit fraction.
    AND #$00FF
    XBA
    CLC
    ADC $0E22,X
    STA $0E22,X           ; Fractional elevation step word.

    ; Sign-extend the integer byte before exchanging it into the low byte.
    ; LDA/AND/BPL/ORA/XBA preserve the fractional ADC carry for the high sum.
    LDA $90
    AND #$FF00
    BPL integerReady
    ORA #$00FF
integerReady:
    XBA
    ADC $0D6E,X
    STA $0D6E,X           ; Signed integer elevation step word.
    RTS
