; Place one sprite DMA chunk, splitting on a $100-word VRAM page when needed.
; File $00A56E..$00A60A (157 bytes). Native JSL $C0A56E / RTL.
; DBR=$7E, decimal clear, M16/X16. Uses DMA fields $0091 profile, $0092
; byte count, $0094/$0096 source, $0097 VRAM-word destination. A/X are
; scratch; Y returns 0 from $C08643. Preserves D, DBR and stack depth.
; Details: docs/graphics.md (Sprite graphics transfer to VRAM).
    .a16
    .i16
transferSpriteChunk:
    ; $C08643 queues unless forced-blank shadow $000D bit 7 selects immediate DMA.
    ; Queue/budget exhaustion waits for interrupt progress. Checked chunks are
    ; even sizes 32/64/128/256; multi-boundary and bank-wrapping cases are open.
    LDA $0092
    LSR A                   ; size in VRAM words
    CLC
    ADC $0097
    DEC A                   ; last word of this chunk
    EOR $0097
    AND #$0100
    BEQ requestWholeChunk   ; bit 8 set => dest range crosses a $100-word page

    LDA $0094
    PHA                     ; original source
    LDA $0092
    PHA                     ; original byte count
    LDA $0097
    PHA                     ; original dest
    CLC
    ADC #$0100
    AND #$FF00
    PHA                     ; page-end dest
    SEC
    SBC $0097
    ASL A
    STA $0092               ; first request: words-to-boundary * 2 bytes
    JSL $C08643             ; inner waits for ring/budget are intentional
    LDA $0094
    CLC
    ADC $0092
    STA $0094               ; source stays consecutive
    PLA
    CLC
    ADC #$0100
    STA $0097               ; second dest = boundary + $100 words
    PLX
    PLA
    PHA
    PHX
    SEC
    SBC $0092
    STA $0092               ; remaining bytes
    JSL $C08643
    PLA
    STA $0097
    PLA
    STA $0092
    PLA
    STA $0094               ; restore original source, size, and dest
    BRA advanceDestination

requestWholeChunk:
    JSL $C08643

advanceDestination:
    LDA $0097
    AND #$0100
    BNE destHasBit8
    LDA $0097
    CLC
    ADC #$0100              ; bit 8 clear: next segment is +$100 words
    STA $0097
    RTL

destHasBit8:
    ; Add 32 * floor((size+32)/64) words, then subtract $100 if bit 8 remains.
    LDA $0092
    CLC
    ADC #$0020
    AND #$FFC0
    LSR A
    CLC
    ADC $0097
    PHA
    EOR $0097
    AND #$0100
    BEQ subtractPage
    PLA
    STA $0097
    RTL
subtractPage:
    PLA
    SEC
    SBC #$0100
    STA $0097
    RTL
