; Find free runtime-definition records without reserving or changing them.
; File $001A9D..$001B14. Native JSL entry, decimal clear, DBR=$7E.
; A is the requested byte count; normal callers request ten bytes per element
; for two variants. Returns A=pool-relative offset, $FF01 for scan exhaustion,
; or $FF02 when a free candidate fails the strict start+size < $0380 test.
; Only each five-byte record's flag byte must equal $FF. Size is also written
; to $4A6A. Preserves D/DBR/stack; A/X/Y and flags are scratch, A/X return 16-bit.
; Owns scratch at caller D-$12: +$02 size, +$04 end, +$0E scan, +$10 candidate.
; There is no size validation or overflow guard. Candidate $037F can inspect
; a flag beyond the initialized pool; adjacent memory can affect failure code.
.a16
.i16
REP #$31
PHD
PHA
TDC
ADC #$FFEE
TCD
PLA
STA $02
LDX #$0000
STX $10
LDA $02
STA $4A6A
BRA checkCandidateBound
inspectCandidate:
LDA $4682,X
AND #$00FF
CMP #$00FF
BEQ checkRequestedEnd
TXA
CLC
ADC #$0005
TAX
STX $10
checkCandidateBound:
CPX #$0380
BCC inspectCandidate
LDA #$FF01
BRA returnResult
checkRequestedEnd:
TXA
CLC
ADC $02
CMP #$0380
BCS insufficientTail
TXA
STA $0E
BRA checkRunEnd
inspectRunRecord:
TAX
LDA $4682,X
AND #$00FF
CMP #$00FF
BEQ advanceRun
LDA $0E
CLC
ADC #$0005
TAX
STX $10
BRA checkCandidateBound
advanceRun:
LDA $0E
CLC
ADC #$0005
STA $0E
checkRunEnd:
LDX $10
TXA
CLC
ADC $02
STA $04
LDA $0E
CMP $04
BCC inspectRunRecord
TXA
BRA returnResult
insufficientTail:
LDA #$FF02
returnResult:
PLD
RTL
