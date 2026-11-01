; Replace the script cursor with a word target when the state value is zero.
; File $00995D..$00996A (14 bytes), SNES $C0995D; JSR/RTS handler $0A.
; Native M16/X16, WRAM DBR, DP+$8A state byte offset, valid [$80] stream.
; Y starts at the target word. Tests full $1516,X, not just its low byte.
; Taken: Y=operand word and A=target. Untaken: Y+=2, A=nonzero state value.
; X=state offset. Preserves D/DBR/widths, stream base/bank and CPU stack depth;
; N/Z are clobbered, other status bits preserved. Cursor arithmetic wraps.
; Evidence: docs/scripts.md (action VM dispatch and script-state fields).
    .a16
    .i16

actionScriptBranchIfZero:
    LDX $8A
    LDA $1516,X
    BNE skipTarget
    ; The operand is a cursor in the existing stream, not a far pointer.
    ; Long indexed reads may cross banks; DP+$82 itself is unchanged.
    LDA [$80],Y
    TAY
    RTS

skipTarget:
    INY
    INY
    RTS
