; Advance one bank-C4 effect sequence until a duration command.
; File $00AD56..$00AD89 (52 bytes), SNES $C0AD56. Near JSR from AC43.
; Native M16/X16, decimal clear, DBR=$7E. A is the output-field base.
; DP+$02/$04 is the C4 long pointer; DP+$88 is the entity byte offset.
; Returns A=new sequence pointer, Y=duration word, X=output address.
; $0001 writes the next word to that output; $0003 replaces DP+$02
; and restarts at Y=0. Any other command takes the next word as Y.
; DP+$08 is scratch. Preserves D, DBR, DP+$04 and stack depth.
; A/X/Y/flags are scratch. Evidence: docs/graphics.md (effect sequences).
    .a16
    .i16

advanceEntityEffectSequence:
    CLC
    ADC $88
    TAX                     ; Output field for this entity.
    LDY #$0000

readSequenceCommand:
    LDA [$02],Y
    INY
    INY
    CMP #$0001
    BNE checkRedirect
    ; Write the following word to the output field, then continue.
    LDA [$02],Y
    INY
    INY
    STA $0000,X
    BRA readSequenceCommand

checkRedirect:
    CMP #$0003
    BNE takeDuration
    ; Replace the sequence pointer; stay in bank C4.
    LDA [$02],Y
    STA $02
    LDY #$0000
    BRA readSequenceCommand

takeDuration:
    LDA [$02],Y
    INY
    INY
    STY $08                 ; Bytes consumed since the last redirect.
    TAY                     ; Duration.
    LDA $02
    CLC
    ADC $08                 ; Advanced pointer, low word only.
    RTS
