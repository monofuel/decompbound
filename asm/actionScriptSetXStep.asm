; actionScriptSetXStep — set the entity's x motion step.
; File $009713..009730; SNES $C09713..C09730.
; JSR/RTS, native M16/X16, WRAM DBR; DP+$88 is the entity byte offset.
; [$80],Y supplies a signed little-endian 8.8 operand; DP+$90 saves it.
; Decimal mode is preserved and does not affect this handler; no ADC is used.
; Replaces the split 16.16 step at $0CF6/$0DAA,X.
; Returns X=entity offset, Y+=2 modulo 65536; stream pointer/bank unchanged.
; A=sign-extended operand integer byte; N/Z reflect final XBA's low byte; C/V preserved.
; Preserves D, DBR and register widths. See docs/scripts.md for dispatch evidence.

    .a16
    .i16
actionScriptSetXStep:
    ; Long indexed reads can cross banks; cursor wrap does not update DP+$82.
    LDX $88
    LDA [$80],Y
    INY
    INY
    STA $90

    ; The operand's fractional byte becomes bits 8..15 of the 16-bit fraction.
    AND #$00FF
    XBA
    STA $0DAA,X           ; Fractional x step word.

    ; Sign-extend the integer byte before exchanging it into the low byte.
    LDA $90
    AND #$FF00
    BPL integerReady
    ORA #$00FF
integerReady:
    XBA
    STA $0CF6,X           ; Signed integer x step word.
    RTS
