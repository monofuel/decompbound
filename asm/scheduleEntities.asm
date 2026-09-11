; Schedule entity scripts and callbacks, file $009466..$009505 (160 bytes).
; JSL entry: native M16/X16, decimal clear, DBR=$7E, valid acyclic lists.
; A nonzero $0A60 lock returns immediately. The active path executes in bank
; $80, sets the lock, and uses D=(caller D-$A0)&$FF00 for interpreter scratch.
; Preserves caller D/DBR/stack depth; A/X/Y and flags are scratch. Callbacks
; must preserve D/DBR, 16-bit widths, and scratch $88 (entity byte offset).
; First pass saves next entity/state in $0A56/$0A58 before execution, allowing
; removal helpers to redirect traversal. Every entity with bit14 clear needs
; a valid nonempty script-state chain rooted at $0ADA,X.
; $10B6 bit14 skips scripts and callback $121E; bit15 skips far callback $107A.
; Second pass always calls $11A6. Callback $121E must also preserve X for that
; dispatch. Second-pass next links are read live: removing the current entity
; can redirect traversal into the free list. Lists and callbacks are trusted.
; Global callback $0A5E runs only after a nonempty second pass. The original
; scheduler is invoked from the frame service; its low bank mirror is required
; for the same-bank callback and interpreter dispatches.
.a16
.i16
LDA $0A60
BEQ enterSchedulerMirror
RTL
enterSchedulerMirror:
JML $809470
schedulerBody:
REP #$30
REP #$20
PHD
PHA
TDC
SEC
SBC #$00A0
AND #$FF00
TCD
PLA
INC $0A60
LDX $0A50
BMI finishScheduler
STZ $80
STZ $86
runEntityScripts:
STX $88
STX $1A44
STX $1A42
LSR $1A42
LDA $0A9E,X
STA $0A56
JSR runScriptChainAndFarCallback
LDX $0A56
BPL runEntityScripts
LDX $0A50
BMI finishScheduler
runEntityCallbacks:
STX $1A42
LSR $1A42
STX $88
BIT $10B6,X
BVS runPositionCallback
JSR ($121E,X)
runPositionCallback:
JSR ($11A6,X)
LDX $88
LDA $0A9E,X
TAX
BPL runEntityCallbacks
LDX #$0000
JSR ($0A5E,X)
finishScheduler:
PLD
STZ $0A60
RTL
runScriptChainAndFarCallback:
BIT $10B6,X
BVS checkFarCallback
LDY $0ADA,X
runScriptState:
STY $8A
STY $1A48
STY $1A46
LSR $1A46
LDA $125A,Y
STA $0A58
JSR $9506
LDY $0A58
BPL runScriptState
LDX $88
checkFarCallback:
LDA $10B6,X
BMI entityFirstPassComplete
STA $0A5C
LDA $107A,X
STA $0A5A
JSL $C09D9E
entityFirstPassComplete:
RTS
