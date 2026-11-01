; Action-script near/far jumps and the word return-address stack.
; File $009649..009684; SNES $C09649..C09684. Four JSR/RTS entries below.
; Native M16/X16, WRAM DBR; DP+$80 is the long stream base, Y the operand PC.
; DP+$8A is the state byte offset; DP+$84 points to its 16-byte work area
; ($15A2 + stateOffset*8). $12E6,X is an unchecked stack byte index.
; D, DBR and widths are preserved. Decimal mode is unused except when an
; empty RETURN detaches the state: that path requires decimal clear.
; See docs/scripts.md for the interpreter, state layout and control flow.

    .a16
    .i16
; Opcode $19; same-bank GOTO. Returns A=Y=target; X and C/V preserved.
; N/Z reflect target; no cursor increment or stream-bank change.
actionScriptNearGoto:
    ; Long indexed reads can cross banks; the resulting Y remains 16 bits.
    LDA [$80],Y
    TAY
    RTS

; Opcode $03; far GOTO. Returns X=Y=target offset; C/V preserved.
; M16 bank load also writes the following stream byte into DP+$83.
; N/Z reflect target; A retains that bank/overread word. D/DBR preserved.
actionScriptFarGoto:
    LDA [$80],Y
    TAX
    ; Cursor arithmetic wraps at 16 bits without updating the stream bank.
    INY
    INY
    LDA [$80],Y
    STA $82                ; Low byte selects bank; high byte is an overread.
    TXY
    RTS

; Opcode $1A; near GOSUB. Pushes Y+2 modulo 65536, then jumps to operand.
; Returns X=state offset, Y=target, A=new stack byte index; C/V preserved.
; DP+$90 saves target; N/Z reflect target. Bank is not pushed or changed.
actionScriptGosub:
    LDA [$80],Y
    STA $90
    INY
    INY
    TYA

    ; Only a return-PC word is stored. There is no capacity/alignment check.
    LDX $8A
    LDY $12E6,X
    STA ($84),Y            ; Short indirect store uses WRAM DBR.
    INY
    INY
    TYA
    STA $12E6,X
    LDY $90
    RTS

; Opcode $1B; RETURN. Nonempty: pops one word into A/Y, X=state offset,
; N/Z reflect return PC; C/V, bank and D/DBR preserved. DP+$94 is scratch.
; Empty: tail-jumps to detach at $99C3, which overwrites DP+$94 with zero.
; That shared tail requires decimal clear and may remove the entity.
actionScriptReturn:
    STY $94
    LDX $8A
    LDY $12E6,X
    BNE popReturnPc
    JMP $99C3              ; Shared detach tail; returns to this handler's caller.

popReturnPc:
    DEY
    DEY
    TYA
    STA $12E6,X
    LDA ($84),Y
    TAY
    RTS
