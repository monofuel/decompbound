; Replace the script cursor with a word target when the state value is nonzero.
; File $00996B..$009978 (14 bytes), SNES $C0996B; JSR/RTS handler $0B.
; Native M16/X16, WRAM DBR, DP+$8A state byte offset, valid [$80] stream.
; Y starts at the target word. Tests full $1516,X, including bit 15.
; Taken: Y=operand word and A=target. Untaken: Y+=2, A=zero.
; X=state offset. Preserves D/DBR/widths, stream base/bank and CPU stack depth;
; N/Z are clobbered, other status bits preserved. Cursor arithmetic wraps.
; Evidence: docs/scripts.md (action VM dispatch and script-state fields).
    .a16
    .i16

actionScriptBranchIfNonzero:
    LDX $8A
    LDA $1516,X
    BEQ skipTarget
    ; The operand is a cursor in the existing stream, not a far pointer.
    ; Long indexed reads may cross banks; DP+$82 itself is unchanged.
    LDA [$80],Y
    TAY
    RTS

skipTarget:
    INY
    INY
    RTS
