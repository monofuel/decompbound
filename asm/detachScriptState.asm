; Detach and recycle a script state; file $009D12..009D5F, SNES $C09D12..C09D5F.
; JSR/RTS, native M16/X16, WRAM DBR, decimal clear. X=entity offset,
; Y=reachable state byte offset in that entity's valid, acyclic state chain.
; Preserves X/Y/D/DBR and stack depth; writes a scratch word at DP-2.
; Unlinks Y, repairs saved-next $0A58 if equal Y, then prepends Y to $0A54.
; Returns A=old free-state head; N/Z reflect A, C from CPY against saved-next,
; V from the search's DP-base subtraction. No missing-state/bounds checks.
; See docs/scripts.md for state-chain ownership and interpreter traversal.

    .a16
    .i16
detachScriptState:
    JSR unlinkScriptState

    ; Reuse the detached state's next link for the free-list chain.
    LDA $0A54
    STA $125A,Y
    STY $0A54
    RTS

; JSR/RTS, same inputs and preconditions; unlink without recycling the state.
; Preserves X/Y/D/DBR; A=original successor. N/Z/C compare Y with old $0A58;
; V comes from DP-base subtraction. The detached node's own link is unchanged.
unlinkScriptState:
    PHX
    JSR findStatePredecessor
    LDA $125A,Y            ; Keep the old successor before changing any links.
    CPX #$FFFF
    BEQ unlinkHead
    STA $125A,X            ; Predecessor bypasses the detached node.
    PLX
    BRA repairSavedNext

unlinkHead:
    PLX
    STA $0ADA,X            ; Head removal changes the entity's root instead.

repairSavedNext:
    ; Scheduler traversal may already have saved this state as its next item.
    CPY $0A58
    BNE unlinkDone
    STA $0A58
unlinkDone:
    RTS

; JSR/RTS, X=entity and Y=reachable state, X16, decimal clear, WRAM DBR.
; Forces M16; returns X=predecessor or $FFFF for head, preserves Y/D/DBR.
; A is preserved for head, otherwise equals target offset. N/Z reflect restored
; D via PLD, C=1 from equal CPY, V from DP-2. Scratch at DP-2 is not restored.
findStatePredecessor:
    REP #$20
    PHD
    PHA
    ; Reserve private direct-page scratch without changing the caller's D.
    TDC
    SEC
    SBC #$0002
    TCD
    PLA
    STY $00                ; Target state, stored at the caller's DP-2.
    LDY $0ADA,X
    LDX #$FFFF             ; Sentinel means target was the chain head.

findState:
    CPY $00
    BEQ foundState
    TYX
    LDA $125A,Y
    TAY
    BRA findState          ; No terminal-link or cycle check exists.

foundState:
    LDY $00
    PLD
    RTS
