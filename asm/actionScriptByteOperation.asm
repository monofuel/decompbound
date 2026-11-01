; Apply a byte AND/OR/add/XOR to an explicitly addressed WRAM value.
; File $009A5C..$009A86 (43 bytes), SNES $C09A5C; JSR/RTS opcode $18.
; Native M16/X16, decimal clear; DBR=$7E or a matching low-WRAM mirror.
; [$80],Y operands: address word, operation byte, immediate byte (four bytes).
; Clobbers A/X/flags, DP+$8C/$90 and global $0A5A..$0A5D; preserves D/DBR.
; Returns M16/X16, X=0, Y+=4 (16-bit wrap), A=zero-extended byte result.
; N/Z describe the byte result; logical operations return C=0 and preserve
; entry V. ADD supplies byte carry/overflow after explicitly clearing C.
; Near JSR $9D9E followed by bank-zero JML/RTS changes PBR to $00; both
; this wrapper's continuation and its caller's return PC must exist there.
; Valid operations are 0..3; no bounds check. See docs/scripts.md (bitops).
    .a16
    .i16

actionScriptByteOperation:
    LDA [$80],Y
    STA $8C                ; 16-bit target address in DBR, not a far pointer.
    INY
    INY
    LDA [$80],Y
    AND #$00FF
    ASL A                  ; Operation byte -> word-table offset; clears C.
    TAX
    INY
    LDA [$80],Y
    STA $90                ; Word read also retains next stream byte in $91.
    INY                    ; Only the low immediate byte is consumed.

    ; Operation table has four near pointers, fetched from fixed ROM bank C0.
    LDA $C09ABD,X
    STA $0A5A              ; Pointer is read back through bank-zero low WRAM.
    LDA #$0000
    STA $0A5C              ; Target bank $00; also clears neighboring $0A5D.
    LDX #$0000
    SEP #$20
    .a8
    ; The target uses RTS, matching this JSR. RTS does not restore PBR:
    ; $9A84 and the subsequent caller continuation execute in bank $00.
    JSR $9D9E
    REP #$20
    .a16
    ; The accumulator high byte remained zero from LDA #$0000 above.
    RTS
