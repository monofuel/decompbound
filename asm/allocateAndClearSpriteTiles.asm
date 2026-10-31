; Reserve 16x16 sprite tile slots and optionally clear their VRAM.
; File $001C52..$001D37 (230 bytes). Native JSL $C01C52, DBR=$7E, decimal clear.
; The return epilogue LDA $14 / PLD / RTL occupies $C01D34..$C01D37, before
; buildSpriteDefinitions at $C01D38.
; A is width in 8-pixel tiles, X is height, Y is the owner tag's low byte.
; Both dimensions are rounded up to even values; the slot count is
; ceil(width/2) * ceil(height/2) via hardwareMultiply16 $C09032 and two LSRs.
; Slots come from allocateSpriteSlots $C01B96. Failure returns A=$FF03 without
; touching occupancy or VRAM. Success returns the starting slot in A.
; If either original dimension was odd, every allocated slot is cleared; if
; both were already even, VRAM is left untouched. Odd-size clearing covers the
; whole reserved run, not only padding tiles.
; Each slot maps through $C42F8C: top 32 VRAM words at $4000 + table[slot]
; (ADC #$4000), bottom 32 words at $4100 + table[slot] (ADC #$4100). Adjacent
; slots are batched up to eight-slot boundaries. Each batch issues two DMA profile-3 requests through
; $C08616, sourcing the zero byte at $C40BE8 (file $040BE8). $C08616 restores
; M16/X16; a .a16 hint after each JSL is required so the following 16-bit
; immediate ADC assembles correctly.
; Temporary direct page at caller D-$1E: $04 original width then current slot,
; $1A original height, $1C owner, $02 even-width/byte-count scratch, $18 even
; height then batch length, $16 slot count, $14 returned slot, $12 exclusive
; end slot, $06/$08 and $0E/$10 fill source $C40BE8, $0A/$0C slot-map pointer.
; Preserves D, DBR and stack depth; A/X/Y and flags are scratch, A/X return
; 16-bit. Positive dimensions whose rounded allocation fits the 88-slot pool
; are the supported contract; zero and oversized requests are unverified.
; Tests: tests/integration_sprite_allocation.nim (3,072 synthetic + 928
; resource header/alloc chains); spawn uses this at $C01EAF.
.a16
.i16
REP #$31
PHD
PHA
TDC
ADC #$FFE2
TCD
PLA
STY $1C
STX $1A
STA $04
INC A
AND #$FFFE
STA $02
LDA $1A
INC A
AND #$FFFE
STA $18
LDY $18
LDA $02
JSL $C09032
LSR A
LSR A
STA $16
LDY $1C
TYX
LDA $16
JSL $C01B96
STA $14
CMP #$7FFF
BCC allocationOk
BEQ allocationOk
LDA $14
JMP returnWithA
allocationOk:
LDA $02
CMP $04
BNE startClear
LDA $18
CMP $1A
BNE startClear
JMP skipClear
startClear:
LDA $14
STA $04
BRA checkClearRange
clearNextBatch:
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
STA $02
LDA #$0BE8
STA $06
LDA #$00C4
STA $08
LDA #$2F8C
STA $0A
LDA #$00C4
STA $0C
LDA $04
ASL A
CLC
ADC $0A
STA $0A
LDA $06
STA $0E
LDA $08
STA $10
LDA [$0A]
CLC
ADC #$4000
TAY
LDX $02
SEP #$20
.a8
LDA #$03
JSL $C08616
.a16
LDA $06
STA $0E
LDA $08
STA $10
LDA [$0A]
CLC
ADC #$4100
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
STA $04
checkClearRange:
LDA $14
CLC
ADC $16
STA $12
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
