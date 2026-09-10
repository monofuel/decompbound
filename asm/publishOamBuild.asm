; Drain sprite queues, finalize packed OAM bits, and publish a completed buffer.
; File $008B26..$008B8D; native JSL entry, DBR=$7E, decimal mode clear.
; Selector word $002E must be 1 or 2; queued definitions must be well formed.
; Cursors and the packing sentinel $000A must be initialized; zero cannot flush.
; Queue drain $C08B8E consumes A/X/Y and preserves the queue counts.
; Long-pointer bank $0009 must alias the same WRAM as DBR for high-table writes.
; The final high-table store is unconditional, including the empty $80 sentinel.
; Eight scroll words $0031..$003F are snapshotted into the selected word lanes.
; Byte $002C publishes the selector; byte $002E toggles the next build with XOR 3.
; Returns A/X/Y 16-bit; preserves DBR, direct page, and stack depth.
; A/X/Y and arithmetic flags are scratch. The DBR=$FF trap is intentional.
.a16
.i16
REP #$30
JSR $8B8E
SEP #$20
.a8
PHB
PLA
CMP #$FF
BNE finalizePackedBits
invalidDataBank:
BRA invalidDataBank
finalizePackedBits:
LDA $000A
CMP #$80
BEQ storeFinalByte
alignPendingPairs:
LSR A
LSR A
BCC alignPendingPairs
storeFinalByte:
LDX $0007
STA $0000,X
REP #$30
.a16
.i16
LDA $002E
DEC A
ASL A
TAX
LDA $0031
STA $0041,X
LDA $0033
STA $0045,X
LDA $0035
STA $0049,X
LDA $0037
STA $004D,X
LDA $0039
STA $0051,X
LDA $003B
STA $0055,X
LDA $003D
STA $0059,X
LDA $003F
STA $005D,X
SEP #$20
.a8
LDA $002E
STA $002C
EOR #$03
STA $002E
REP #$30
.a16
.i16
RTL
