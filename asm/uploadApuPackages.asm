; Upload APU packages, file $00AB06..00ABBC / SNES $C0AB06..C0ABBC (183 bytes).
; JSL/RTL: native A16/X16, decimal clear; A=stream address, X low byte=bank.
; Entry DBR must map absolute $00C6..C9 to low WRAM (zero or a valid mirror).
; Those pointer stores precede DBR/DP zero setup; incoming D is preserved.
; Saves/restores D/DBR; clobbers A/X/Y/flags. Returns M16/X16 with NMI enabled.
; Waits for AA/BB, requests reset with $FF if needed, then streams addresses,
; flags and counter/data words. A zero length sends end flag zero/address $0500.
; Waits for port-zero/one word zero. Receiver return/entry policy is separate.
; Y is a wrapping 16-bit stream index; no package bounds check. See docs/audio.md.
    .a16
    .i16
    REP #$30
    .a16
    .i16
    STA $00C6
    STX $00C8
    PHB
    PEA $0000
    PLB
    PLB
    PHD
    PEA $0000
    PLD
    LDY #$00
    LDA $2140
    CMP #$BBAA
    BEQ iplReady
    JSR requestUploadReceiver

iplReady:
    ; Mask NMI while the stream and communication ports are owned by this call.
    SEP #$20
    .a8
    .i16
    LDA $001E
    AND #$7F
    STA $001E
    STA $004200
    LDA #$CC
    BRA beginBlock

readPayloadByte:
    ; The first payload token is zero; XBA pairs its data byte with that token.
    LDA [$C6],Y
    INY
    XBA
    LDA #$00
    BRA sendWord

nextPayloadByte:
    ; Send one counter/data word only after the previous counter is acknowledged.
    XBA
    LDA [$C6],Y
    INY
    XBA

waitPort0Match:
    CMP $2140
    BNE waitPort0Match
    INC A

sendWord:
    REP #$20
    .a16
    .i16
    STA $2140
    SEP #$20
    .a8
    .i16
    DEX
    BNE nextPayloadByte

waitPort0AfterBlock:
    CMP $2140
    BNE waitPort0AfterBlock

avoidZeroCounter:
    ; Equal CMP leaves C=1: ADC #3 advances by four, retrying if the token is zero.
    ADC #$03
    BEQ avoidZeroCounter

beginBlock:
    ; Only nonzero lengths consume a destination word and payload from the stream.
    PHA
    REP #$20
    .a16
    .i16
    LDA [$C6],Y
    BNE nonEmptyBlock
    TAX
    LDA #$0500
    BRA writeBlockAddr

nonEmptyBlock:
    TAX
    INY
    INY
    LDA [$C6],Y
    INY
    INY

writeBlockAddr:
    ; Flag is length>=1. ADC #$7F sets V for nonempty blocks; PLA preserves it.
    STA $2142
    SEP #$20
    .a8
    .i16
    CPX #$01
    LDA #$00
    ROL A
    STA $2141
    ADC #$7F
    PLA
    STA $2140

waitHeaderAck:
    CMP $2140
    BNE waitHeaderAck
    BVS readPayloadByte
    REP #$20
    .a16
    .i16

waitTransferIdle:
    ; The routine waits for the full port-zero/one word to clear before returning.
    LDA $2140
    BNE waitTransferIdle
    SEP #$20
    .a8
    .i16
    LDA $001E
    ORA #$80
    STA $001E
    STA $004200
    REP #$20
    .a16
    .i16
    PLD
    PLB
    RTL

requestUploadReceiver:
    ; Request the resident reset/upload path with $FF until AA/BB is published.
    STZ $2142
    STZ $2140

waitIplReady:
    LDA #$FF
    STA $2140
    LDA $2140
    CMP #$BBAA
    BNE waitIplReady
    RTS
