; Place one sprite DMA chunk, splitting on a $100-word VRAM page when needed.
; File $00A56E..$00A60A (157 bytes). Native JSL $C0A56E, decimal clear.
; Uses the public DMA request fields consumed by $C08643: $0091 profile,
; $0092 byte count, $0094/$0096 source, $0097 VRAM word destination.
; If (dest + size/2 - 1) XOR dest has bit 8 set, the destination range crosses
; a $100-word boundary. The first request ends at that boundary; the second
; starts $100 words later. Source bytes stay consecutive. After a split the
; original source offset and byte count are restored; $0097 is then advanced
; for the next sprite segment.
; Destination advancement: if the original dest has bit 8 clear, add $100.
; Otherwise add 32 * floor((size+32)/64) words, then subtract $100 if bit 8
; is still set. This is the verified contract for the tested even sizes
; 32/64/128/256. Oversized requests crossing multiple boundaries and
; source-bank wrapping remain outside that check.
; $C08643 queues into the $0400 ring when forced-blank shadow $000D bit 7 is
; clear, or DMAs immediately on channel 1 when it is set. Inner waits for
; interrupt progress if queued bytes would exceed $1200 or the ring would
; fill; those spins are intentional. This file does not adopt $C08643 or the
; interrupt drain at $C08238.
; Preserves D, DBR and stack depth; A/X are scratch; Y returns 0 from $C08643.
; Tests: tests/integration_sprite_dma.nim 256 synthetic placements plus the
; resource and full-upload cases.
.a16
.i16
LDA $0092
LSR A
CLC
ADC $0097
DEC A
EOR $0097
AND #$0100
BEQ requestWholeChunk
LDA $0094
PHA
LDA $0092
PHA
LDA $0097
PHA
CLC
ADC #$0100
AND #$FF00
PHA
SEC
SBC $0097
ASL A
STA $0092
JSL $C08643
LDA $0094
CLC
ADC $0092
STA $0094
PLA
CLC
ADC #$0100
STA $0097
PLX
PLA
PHA
PHX
SEC
SBC $0092
STA $0092
JSL $C08643
PLA
STA $0097
PLA
STA $0092
PLA
STA $0094
BRA advanceDestination
requestWholeChunk:
JSL $C08643
advanceDestination:
LDA $0097
AND #$0100
BNE destHasBit8
LDA $0097
CLC
ADC #$0100
STA $0097
RTL
destHasBit8:
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
