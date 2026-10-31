; Read a sprite resource's width, height, and layout ID.
; File $001DED..$001E48 (92 bytes). Native same-bank JSR $C01DED, RTS exit.
; DBR=$7E, decimal clear. A is the resource ID. The four-byte pointer table at
; $EF133F (file $2F133F) is indexed by A*4; there is no ID bounds check.
; Resource byte 1 shifted right four becomes width in 8-pixel tiles at $467A.
; Resource byte 0 becomes height at $467C. Resource byte 2 returns in A as the
; layout ID. Other resource bytes are unread here.
; Temporary direct page at caller D-$10: $0E resource ID, $0A/$0C table then
; resource pointer, $06/$08 resource far pointer. Y is scratch; X is unused.
; Preserves D, DBR, X and stack depth; returns M/X16. Spawn calls this at
; $C01EA2 before allocateAndClearSpriteTiles. Tests:
; tests/integration_sprite_allocation.nim resource chain from $C01EA0, and
; tests/integration_sprite_spawn.nim full wrapper.
.a16
.i16
REP #$31
PHD
PHA
TDC
ADC #$FFF0
TCD
PLA
STA $0E
LDA #$133F
STA $0A
LDA #$00EF
STA $0C
LDA $0E
ASL A
ASL A
CLC
ADC $0A
STA $0A
LDY #$0002
LDA [$0A],Y
TAY
LDA [$0A]
STA $06
STY $08
SEP #$20
.a8
LDY #$0001
LDA [$06],Y
LSR A
LSR A
LSR A
LSR A
REP #$20
.a16
AND #$00FF
STA $467A
LDA $06
STA $0A
LDA $08
STA $0C
LDA [$0A]
AND #$00FF
STA $467C
SEP #$20
.a8
LDY #$0002
LDA [$06],Y
REP #$20
.a16
AND #$00FF
PLD
RTS
