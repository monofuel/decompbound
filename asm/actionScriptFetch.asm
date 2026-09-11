; actionScriptFetch — execute one action-script state tick.
; File $009506..009557; JSR entry, native M16/X16, decimal clear, WRAM DBR.
; DP+$88 is the entity byte offset; DP+$8A is the script-state byte offset.
; A state owns wait $1372, PC $13FE, bank $148A, and work register $1516.
; DP+$80/$81 must provide the stream base; DP+$82 receives the state bank.
; The state byte offset times eight plus $15A2 becomes DP+$84: sixteen bytes
; per state ID. TODO: explain every field in this work area.
; A nonzero entry wait is decremented without fetching. Otherwise dispatch
; continues until a handler sets a nonzero wait; the cursor is saved and the
; wait is decremented in the same tick. Thus WAIT 1 resumes next tick.
; Low opcodes dispatch through $9558. High opcodes set a four-bit wait and
; dispatch through $95E2 using bits 4–6. Handlers receive Y after the opcode.
; Clobbers A/X/Y and stream/dispatch scratch. Behavioral and byte checks:
; tests/integration_action_script_fetch.nim.

.a16
.i16
LDX $8A
LDA $1372,X
BNE waitTick
LDY $13FE,X
LDA $148A,X
STA $82
TXA
ASL A
ASL A
ASL A
ADC #$15A2
STA $84
fetchOpcode:
LDA [$80],Y
INY
AND #$FF
CMP #$70
BCS highPath
ASL A
TAX
JSR ($9558,X)
BRA afterDispatch
highPath:
STA $90
AND #$0F
STA $1372,X
LDA $90
AND #$70
LSR A
LSR A
LSR A
TAX
JSR ($95E2,X)
afterDispatch:
LDX $8A
LDA $1372,X
BEQ fetchOpcode
TYA
STA $13FE,X
LDA $82
STA $148A,X
waitTick:
DEC $1372,X
RTS
