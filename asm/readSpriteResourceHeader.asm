; Read a sprite resource's width, height, and layout ID.
; File $001DED..$001E48 (92 bytes). Native same-bank JSR $C01DED / RTS.
; DBR=$7E, decimal clear, M16/X16. A=resource ID, no bounds check.
; Stores width in 8-pixel tiles at $467A, height at $467C, and returns
; the layout ID in A. Temporary DP at caller D-$10. Preserves D, DBR, X
; and stack depth. Details: docs/graphics.md (Resource and layout tables).
    .a16
    .i16
readSpriteResourceHeader:
    REP #$31
    PHD
    PHA
    TDC
    ADC #$FFF0              ; D := D-$10
    TCD
    PLA
    STA $0E                 ; resource ID

    LDA #$133F
    STA $0A
    LDA #$00EF
    STA $0C                 ; pointer table $EF133F
    LDA $0E
    ASL A
    ASL A
    CLC
    ADC $0A
    STA $0A                 ; table + resource ID * 4
    LDY #$0002
    LDA [$0A],Y
    TAY
    LDA [$0A]
    STA $06
    STY $08                 ; resource far pointer

    SEP #$20
    .a8
    LDY #$0001
    LDA [$06],Y             ; resource byte 1
    LSR A
    LSR A
    LSR A
    LSR A
    REP #$20
    .a16
    AND #$00FF
    STA $467A               ; width in 8-pixel tiles

    LDA $06
    STA $0A
    LDA $08
    STA $0C
    LDA [$0A]
    AND #$00FF
    STA $467C               ; height in 8-pixel tiles

    SEP #$20
    .a8
    LDY #$0002
    LDA [$06],Y             ; resource byte 2
    REP #$20
    .a16
    AND #$00FF              ; layout ID in A
    PLD
    RTS
