; Decode one inline graphics-entry word and transfer its remaining chunks.
; File $00A53F..$00A56D (47 bytes). Native JSL $C0A53F, or fall-through
; from uploadSpriteFrame. DBR=$7E, decimal clear, M16/X16. Y=entity byte
; offset; DP $02/$04 is the selected entry. Y becomes 0 after the first
; chunk. DP $00=remaining chunks; $0092=bytes/chunk; $0097=VRAM-word dest.
; Preserves D, DBR and stack depth.
; Details: docs/graphics.md (Sprite graphics transfer to VRAM).
    .a16
    .i16
readSpriteGraphicsEntry:
    LDA [$02]
    STA $341A,Y             ; retained entry, including flag bits
    AND #$FFF0
    STA $0094               ; source offset = entry address bits
    SEP #$20
    .a8
    LDA #$00
    STA $0091               ; DMA profile 0
    LDA $2A42,Y
    STA $0096               ; source bank
    REP #$20
    .a16
transferNextChunk:
    JSL $C0A56E             ; transferSpriteChunk; Y returns 0
    DEC $00
    BEQ transfersDone
    LDA $0094
    CLC
    ADC $0092               ; next source = previous + bytes per chunk
    STA $0094
    BRA transferNextChunk
transfersDone:
    RTL
