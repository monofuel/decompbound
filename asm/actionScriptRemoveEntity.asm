; actionScriptRemoveEntity — remove the current entity and stop state traversal.
; File $0095F2..009602; SNES $C095F2..C09602. Opcode $00 or detach tail.
; JSR/RTS or tail JMP, native M16/X16, WRAM DBR, decimal clear.
; DP+$88 is entity byte offset, DP+$8A current state byte offset; Y is preserved.
; $9C3B removes an active entity and recycles its states; inactive is a no-op.
; Sets current-state wait and saved-next $0A58 to $FFFF, including after no-op.
; Returns A=$FFFF, X=state offset, N=1/Z=0; C/V are helper scratch.
; Preserves Y/D/DBR/widths/stack depth. See docs/scripts.md for removal evidence.

    .a16
    .i16
actionScriptRemoveEntity:
    LDX $88
    JSR $9C3B              ; Preserves X/Y/A; unlinks/recycles the entity.

    ; The fetch loop still saves its cursor and decrements this wait to $FFFE.
    LDX $8A
    LDA #$FFFF
    STA $1372,X
    STA $0A58              ; Prevent visiting another state of the removed entity.
    RTS
