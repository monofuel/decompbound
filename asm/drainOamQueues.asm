; Drain the four sprite queues into the current OAM build buffer.
; File $008B8E..$008C53, SNES $C08B8E; 198 bytes. JSR entry from publishOamBuild.
; Native X16, decimal-clear callers; PHP/PLP restore the caller's status.
; Queues 0..3 are emitted in that order, insertion order within each queue.
; Counts at $2504/$2606/$2708/$280A are compared as end indexes and are not
; cleared. For each record: bank word -> $000B, definition pointer in A,
; origin X/Y in X/Y, then JSL $C08CD5 (emitSpriteElements). The emitter
; reads only the low byte of $000B. Word $2402 is compared to 0, 1, 2, 3
; immediately before each queue. A match JSRs queueIndexStub, a lone RTS at
; $C08C53. That JSR is a no-op: it does not skip, flush, or reorder the
; upcoming queue. Purpose of $2402 is unresolved. Empty counts fall through
; the CPX/BCC without calling the emitter. Preserves DBR, direct page, and
; stack depth; A/X/Y and arithmetic flags are scratch. The trailing stub RTS
; is inside this adopted span, after the real PLP/RTS return.
; Tests: integration_oam_publish.nim (0..128 sprites, $2402 = count mod 5),
; integration_oam_emit.nim (emitter contract), integration_oam_build.nim
; (count clears before entity processing).
.a16
.i16
PHP
REP #$20
.a16
LDA $2402
CMP #$0000
BNE drainQueue0
JSR queueIndexStub
drainQueue0:
LDX #$0000
BRA checkQueue0
emitQueue0:
LDA $24C4,X
STA $000B
PHX
LDA $2404,X
PHA
LDA $2484,X
TAY
LDA $2444,X
TAX
PLA
JSL $C08CD5
PLX
INX
INX
checkQueue0:
CPX $2504
BCC emitQueue0
LDA $2402
CMP #$0001
BNE drainQueue1
JSR queueIndexStub
drainQueue1:
LDX #$0000
BRA checkQueue1
emitQueue1:
LDA $25C6,X
STA $000B
PHX
LDA $2506,X
PHA
LDA $2586,X
TAY
LDA $2546,X
TAX
PLA
JSL $C08CD5
PLX
INX
INX
checkQueue1:
CPX $2606
BCC emitQueue1
LDA $2402
CMP #$0002
BNE drainQueue2
JSR queueIndexStub
drainQueue2:
LDX #$0000
BRA checkQueue2
emitQueue2:
LDA $26C8,X
STA $000B
PHX
LDA $2608,X
PHA
LDA $2688,X
TAY
LDA $2648,X
TAX
PLA
JSL $C08CD5
PLX
INX
INX
checkQueue2:
CPX $2708
BCC emitQueue2
LDA $2402
CMP #$0003
BNE drainQueue3
JSR queueIndexStub
drainQueue3:
LDX #$0000
BRA checkQueue3
emitQueue3:
LDA $27CA,X
STA $000B
PHX
LDA $270A,X
PHA
LDA $278A,X
TAY
LDA $274A,X
TAX
PLA
JSL $C08CD5
PLX
INX
INX
checkQueue3:
CPX $280A
BCC emitQueue3
PLP
RTS
queueIndexStub:
RTS
