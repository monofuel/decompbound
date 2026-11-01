; actionScriptDetachState — unlink and recycle the current script state.
; File $0099C3..0099DC; SNES $C099C3..C099DC. Opcode $0C or RETURN tail.
; JSR/RTS or tail JMP; native M16/X16, WRAM DBR, decimal clear.
; DP+$88 entity offset, DP+$8A attached state offset, Y cursor to preserve.
; Requires a valid reachable state in the entity chain; no missing-state check.
; Frees state and sets its wait=$FFFF; updates saved-next $0A58 if needed.
; If states remain: X=entity, Y=input cursor, A=remaining-state head,
; N/Z reflect cursor; C compares state with saved-next, V comes from helper SBC.
; Last state: tail-removes entity via $95F2; X=state, Y=state, A=$FFFF.
; D/DBR/widths preserved; DP+$94 and DP-2 scratch. See docs/scripts.md.

    .a16
    .i16
actionScriptDetachState:
    STY $94
    LDY $8A
    LDX $88
    ; $9D12 preserves X/Y/D/DBR, unlinks Y from entity X, and pushes Y onto
    ; free head $0A54. It replaces $0A58 with the old successor when equal Y.
    ; Its $9D3E search uses a word at DP-2 and requires decimal clear for SBC.
    JSR $9D12
    LDA #$FFFF
    STA $1372,Y            ; Stops this fetch tick, even though state is now free.

    LDA $0ADA,X            ; Entity's remaining script-state chain head.
    BPL restoreCursor
    ; $95F2 removes the entity, sets wait/$0A58=$FFFF, and leaves Y=state.
    JMP $95F2

restoreCursor:
    LDY $94                ; Empty RETURN entered this tail with Y=0.
    RTS
