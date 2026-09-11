; Mark both variants of a runtime sprite definition free.
; File $001B15..$001B95. Native JSL entry, decimal clear, DBR=$7E.
; A is an absolute pool pointer. Valid callers pass a completed two-variant
; definition whose five-byte records terminate each variant with flag bit 7.
; All five bytes of each visited record become $FF. The original flag is
; examined before overwriting it. Preserves D/DBR/stack; A/X/Y and flags are
; scratch, A/X return 16-bit. Scratch lives at caller D-$12: +$02 terminators,
; +$0E flag address, +$10 pool-relative record offset.
; Initial range check accepts $467E..$49FE inclusive, including one-past-pool.
; No alignment or subsequent bound check exists; malformed input can overwrite
; beyond the pool. An already-free $FF flag counts as a variant terminator.
.a16
.i16
REP #$31
PHD
PHA
TDC
ADC #$FFEE
TCD
PLA
CMP #$467E
BCC returnToCaller
CMP #$49FE
BEQ pointerAccepted
BCS returnToCaller
pointerAccepted:
SEC
SBC #$467E
STA $10
LDA #$0000
STA $02
BRA checkVariantCount
releaseRecord:
LDA $10
CLC
ADC #$4682
TAX
STX $0E
LDA $0000,X
AND #$00FF
TAY
LDA $10
TAX
SEP #$20
.a8
LDA #$FF
STA $467E,X
REP #$20
.a16
LDA $10
TAX
SEP #$20
.a8
LDA #$FF
STA $467F,X
REP #$20
.a16
LDA $10
TAX
SEP #$20
.a8
LDA #$FF
STA $4680,X
REP #$20
.a16
LDA $10
TAX
SEP #$20
.a8
LDA #$FF
STA $4681,X
LDX $0E
STA $0000,X
REP #$20
.a16
LDA $10
CLC
ADC #$0005
STA $10
TYA
AND #$0080
BEQ releaseRecord
INC $02
checkVariantCount:
LDA $02
CMP #$0002
BCC releaseRecord
returnToCaller:
PLD
RTL
