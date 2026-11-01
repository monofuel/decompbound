; Position candidate lookup, file $0068F4..0069AE / SNES $C068F4 (187B).
; Native JSL/RTL, decimal clear, DBR=$7E; A=first position, X=second position.
; If $5DD8!=0, preserve candidate/pointer. Otherwise publish $5DD6 and $5E38/3A.
; Tables/records stay extracted: map index=(A>>8)+32*(X div128), wrapped16;
; selected map byte indexes a bank-CF record-list offset masked to 15 bits.
; Lists are unchecked 4B records; unmatched conditions advance low pointer only.
; $5DDA=0 and candidate!=$5DD4 sends port-one command2; otherwise no notification.
; Preserve D/DBR, balance native frame; clobber A/X/Y/flags, DP(D-18)..(D-1),
; absolute division scratch $00B0..B3 and nested predicate scratch below this frame.
    .a16
    .i16
resolvePositionSongCandidate:
    REP #$31
    PHD
    PHA
    TDC
    ADC #$FFEE
    TCD
    PLA
    STA $10
    LDA $5DD8
    BEQ positionSongLookupEnabled
    JMP positionSongLookupReturn

positionSongLookupEnabled:
    ; Quantize positions independently; the division helper returns unsigned quotient A.
    LDA $10
    XBA
    AND #$00FF
    STA $02
    LDY #$0080
    TXA
    JSL $C0915B
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    CLC
    ADC $02
    TAX
    LDA $DCD637,X           ; Low byte only; the word read also reads the next map byte.
    AND #$00FF
    STA $10
    LDA #$0000
    STA $0A
    LDA #$00CF
    STA $0C
    LDA $10
    ASL A
    TAX
    LDA $CF58EF,X           ; Structural record-list offset, not an inline source table.
    AND #$7FFF
    CLC
    ADC $0A
    STA $0A

positionSongTestRecord:
    LDA $0A
    STA $06
    LDA $0C
    STA $08
    LDA [$06]
    BEQ positionSongRecordFound
    AND #$7FFF
    JSL $C21628             ; Return boolean event-flag state for the masked flag number.
    STA $0E
    LDX #$0000
    LDA [$06]
    CMP #$8000
    BCC positionSongRecordPolarity
    BEQ positionSongRecordPolarity
    LDX #$0001              ; Strictly greater than $8000 requires flag set; others clear.
positionSongRecordPolarity:
    STX $02
    LDA $0E
    CMP $02
    BEQ positionSongRecordFound
    LDA #$0004
    CLC
    ADC $0A                ; Wrap low16 only; do not carry into bank CF.
    STA $0A
    BRA positionSongTestRecord

positionSongRecordFound:
    LDA $0A
    STA $06
    LDA $0C
    STA $08
    LDA $06
    STA $5E38
    LDA $08
    STA $5E3A
    SEP #$20
    LDY #$0002
    LDA [$0A],Y            ; Candidate byte; +3 is retained for the separate consumer.
    REP #$20
    AND #$00FF
    TAX
    STX $5DD6
    LDA $5DDA
    BNE positionSongLookupReturn
    CPX $5DD4
    BEQ positionSongLookupReturn
    LDA #$0002
    JSL $C0AC0C             ; Publish command OR protocol-toggle byte, then flip bit7.
positionSongLookupReturn:
    PLD
    RTL
