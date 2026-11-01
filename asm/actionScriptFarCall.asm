; Action-script far calls; file $009685..0096C2, SNES $C09685..C096C2.
; JSR/RTS entries in a matching ROM mirror; native M16/X16, WRAM DBR.
; DP+$80 is stream base, Y cursor, $8A state offset, $84=$15A2+stateOffset*8.
; $12E6,X is unchecked byte index into the state's 16-byte work area.
; Records contain return-PC word and bank byte; M16 accesses spill/overread
; one additional byte. No record-type, capacity, alignment or underflow checks.
; Preserves D/DBR/widths; decimal unused except empty return needs decimal clear.
; See docs/scripts.md for dispatch, software-stack and detach evidence.

    .a16
    .i16
; Opcode $04: consumes target offset word plus bank byte; pushes return record.
; Returns X=state, Y=target, A=target bank/overread word; N/Z reflect Y, C/V
; preserved. DP+$8C/$8E save target; DP+$82/$83 receive bank/overread word.
actionScriptFarCall:
    LDA [$80],Y
    STA $8C
    ; INY wraps modulo 65536 without changing source bank; long reads can carry
    ; across banks, including the high byte overread after the bank operand.
    INY
    INY
    LDA [$80],Y
    STA $8E
    INY
    TYA

    LDX $8A
    LDY $12E6,X
    STA ($84),Y            ; Return cursor is operand cursor+3 modulo 65536.
    INY
    INY
    LDA $82
    STA ($84),Y            ; Saves bank and DP+$83, spilling past the record.
    INY
    TYA
    STA $12E6,X

    LDA $8E
    STA $82                ; Only low byte addresses stream; high byte is scratch.
    LDY $8C
    RTS

; Opcode $05 at $96AA: pop three bytes, restoring bank and return cursor.
; Nonempty: X=state, A=Y=return cursor, N/Z reflect Y, C/V preserved.
; Bank word read includes byte after record and overwrites DP+$83 with it.
; Empty: Y=0 enters detach tail $99C3, so saved cursor becomes zero; entity
; removal may instead return Y=state. Other flags follow that shared tail.
actionScriptFarReturn:
    LDX $8A
    LDY $12E6,X
    BNE popFarRecord
    JMP $99C3

popFarRecord:
    DEY
    LDA ($84),Y
    STA $82
    DEY
    DEY
    TYA
    STA $12E6,X
    LDA ($84),Y
    TAY
    RTS
