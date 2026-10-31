; Decode one inline graphics-entry word and transfer its remaining chunks.
; File $00A53F..$00A56D (47 bytes). Native JSL $C0A53F, or fall-through from
; uploadSpriteFrame. DBR=$7E, decimal clear. Y is the entity byte offset.
; DP $02/$04 is a far pointer to the selected entry. LDA [$02] is stored in
; $341A,Y including flag bits. Address bits (entry & $FFF0) become source
; offset $0094; source bank $0096 comes from $2A42,Y; DMA profile $0091 is 0.
; DP $00 is the remaining chunk count, $0092 the bytes per chunk, $0097 the
; current VRAM destination. Each iteration calls transferSpriteChunk $C0A56E,
; then advances $0094 by $0092. Supported transfer sizes are the even values
; exercised with the wrapper (32/64/128/256 bytes and the 16 resource
; count/size combinations). Source-bank wrapping is unverified.
; Preserves D, DBR and stack depth; Y is clobbered by the transfer helper
; (returns 0) after the first chunk. Tests: tests/integration_sprite_dma.nim
; short entry-path cases and the full-upload fall-through.
.a16
.i16
LDA [$02]
STA $341A,Y
AND #$FFF0
STA $0094
SEP #$20
.a8
LDA #$00
STA $0091
LDA $2A42,Y
STA $0096
REP #$20
.a16
transferNextChunk:
JSL $C0A56E
DEC $00
BEQ transfersDone
LDA $0094
CLC
ADC $0092
STA $0094
BRA transferNextChunk
transfersDone:
RTL
