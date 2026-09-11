; Entity and script-state list helpers, file $009C35..$009CD6 (162 bytes).
; Native M16/X16, decimal clear, DBR=$7E. Links are doubled slot offsets;
; negative links terminate lists. Active entities must occur in the active
; list; all traversed chains must be valid and acyclic. No bounds checks exist.
; $0A50/$0A52 are active/free entity heads; $0A9E,X is the shared next link.
; $0A54 is the free script-state head; $0ADA,X roots an entity's state chain,
; whose next links are $125A,Y. $0A56 is the saved next entity during traversal.
; Removal is used by explicit sprite cleanup at $C0218E and action opcode $00
; at $C095F4. Constructor $C093B3 appends a newly allocated entity.
.a16
.i16
removeEntityById:
; JSL entry: A=entity ID. Returns A=X=twice ID; preserves Y, D, DBR and stack.
ASL A
TAX
JSR removeEntityByOffset
RTL
removeEntityByOffset:
; JSR entry: X=entity offset. Preserves A/X/Y/D/DBR; flags are scratch.
; Negative script IDs are already inactive and cause no list writes.
PHA
LDA $0A62,X
BMI removalComplete
PHY
LDA #$FFFF
STA $0A62,X
JSR $9DA1
JSR returnScriptStateChain
JSR unlinkActiveEntity
JSR prependFreeEntity
PLY
removalComplete:
PLA
RTS
appendActiveEntity:
; JSR entry: X=detached entity offset. Returns A=X=offset; Y is scratch.
LDA #$FFFF
STA $0A9E,X
TXA
LDX $0A50
BPL findActiveTail
STA $0A50
BRA appendedEntity
findActiveTail:
TXY
LDX $0A9E,Y
BPL findActiveTail
STA $0A9E,Y
appendedEntity:
TAX
RTS
unlinkActiveEntity:
; X must be present in the active list. Preserve its successor before its
; link is repurposed; update the saved-next iterator only when it names X.
JSR findActivePredecessor
LDA $0A9E,X
CPY #$FFFF
BEQ unlinkActiveHead
STA $0A9E,Y
BRA updateSavedNext
unlinkActiveHead:
STA $0A50
updateSavedNext:
CPX $0A56
BNE unlinkedEntity
STA $0A56
unlinkedEntity:
RTS
prependFreeEntity:
LDA $0A52
STA $0A9E,X
STX $0A52
RTS
returnScriptStateChain:
; Prepend the entire chain without reversing its internal order. The old
; entity chain pointer remains unchanged; a negative head does nothing.
LDA $0ADA,X
BMI stateChainReturned
PHX
LDA $0A54
PHA
LDA $0ADA,X
STA $0A54
findStateChainTail:
TAX
LDA $125A,X
BPL findStateChainTail
PLA
STA $125A,X
PLX
stateChainReturned:
RTS
findActivePredecessor:
; Returns Y=predecessor or $FFFF for the head; preserves X/D/DBR.
; Uses one scratch word at caller D-2. No missing-target termination exists.
REP #$20
PHD
PHA
TDC
SEC
SBC #$0002
TCD
PLA
STX $00
LDY #$FFFF
LDX $0A50
compareActiveTarget:
CPX $00
BEQ activePredecessorFound
TXY
LDA $0A9E,X
TAX
BRA compareActiveTarget
activePredecessorFound:
LDX $00
PLD
RTS
