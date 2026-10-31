; Reserve 16x16 sprite tile slots and optionally clear their VRAM.
; File $001C52..$001D37 (230 bytes). Native JSL $C01C52 / RTL.
; DBR=$7E, decimal clear, M16/X16. A=width in 8-pixel tiles, X=height,
; Y=owner-tag low byte. Success returns the starting slot in A; failure
; returns A=$FF03 with occupancy and VRAM unchanged. Temporary DP at
; caller D-$1E. Preserves D, DBR and stack depth; A/X/Y are scratch.
; Details: docs/graphics.md (Sprite allocation and clearing).
    .a16
    .i16
allocateAndClearSpriteTiles:
    REP #$31
    PHD
    PHA
    TDC
    ADC #$FFE2              ; D := D-$1E
    TCD
    PLA
    STY $1C                 ; owner-tag low byte
    STX $1A                 ; original height, 8-pixel tiles
    STA $04                 ; original width, 8-pixel tiles

    ; Pool slots are 16x16 pixels, so round the 8-pixel dimensions up to even.
    ; Checked requests are positive and fit 88 slots; zero/oversized are unverified.
    INC A
    AND #$FFFE
    STA $02                 ; width rounded up to even
    LDA $1A
    INC A
    AND #$FFFE
    STA $18                 ; height rounded up to even

    LDY $18
    LDA $02
    JSL $C09032             ; evenWidth * evenHeight
    LSR A
    LSR A
    STA $16                 ; slot count = ceil(W/2) * ceil(H/2)

    LDY $1C
    TYX
    LDA $16
    JSL $C01B96             ; allocateSpriteSlots
    STA $14
    CMP #$7FFF
    BCC allocationOk
    BEQ allocationOk
    LDA $14
    JMP returnWithA

allocationOk:
    ; Odd width or height rounded the reservation up. Clear every allocated
    ; slot, including tiles that already fitted an even size. Both-even
    ; requests leave VRAM untouched.
    LDA $02
    CMP $04
    BNE startClear
    LDA $18
    CMP $1A
    BNE startClear
    JMP skipClear

startClear:
    LDA $14
    STA $04                 ; current slot = start
    BRA checkClearRange

clearNextBatch:
    ; Batch length is min(distance to next 8-slot boundary, remaining slots).
    LDA $04
    CLC
    ADC #$0008
    AND #$00F8
    SEC
    SBC $04
    STA $18
    LDA $12
    SEC
    SBC $04
    CMP $18
    BCS keepBoundaryBatch
    STA $18

keepBoundaryBatch:
    LDA $18
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    STA $02                 ; bytes = slots * 64 (32 VRAM words)

    LDA #$0BE8
    STA $06
    LDA #$00C4
    STA $08                 ; fill source $C40BE8 (zero byte)
    LDA #$2F8C
    STA $0A
    LDA #$00C4
    STA $0C                 ; slot map $C42F8C
    LDA $04
    ASL A
    CLC
    ADC $0A
    STA $0A                 ; pointer to this slot's VRAM word

    LDA $06
    STA $0E
    LDA $08
    STA $10
    LDA [$0A]
    CLC
    ADC #$4000              ; top 32 VRAM words
    TAY
    LDX $02
    SEP #$20
    .a8
    LDA #$03                ; DMA profile 3
    JSL $C08616             ; restores M16/X16
    .a16                    ; 16-bit ADC below needs this hint

    LDA $06
    STA $0E
    LDA $08
    STA $10
    LDA [$0A]
    CLC
    ADC #$4100              ; bottom 32 VRAM words
    TAY
    LDX $02
    SEP #$20
    .a8
    LDA #$03
    JSL $C08616
    .a16

    LDA $04
    CLC
    ADC $18
    STA $04                 ; advance by this batch

checkClearRange:
    LDA $14
    CLC
    ADC $16
    STA $12                 ; exclusive end slot
    STA $02
    LDA $04
    CMP $02
    BCS skipClear
    BEQ skipClear
    JMP clearNextBatch

skipClear:
    LDA $14
returnWithA:
    PLD
    RTL
