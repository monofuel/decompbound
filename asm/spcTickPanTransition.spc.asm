; Advance pan transition, APU $0C79..$0C8B / file $2607BB..$2607CD.
; CALL/shared tail from channel update $0C40: DP zero, even X in 0..14.
; Decrements nonzero DP $91+X, updates position $0330/$0331+X, and marks
; dirty mask $5E using caller mask $47. Preserves X; clobbers A/Y/PSW and
; helper scratch $14..$17 when active, plus stereo scratch $10..$12 if written.
; Dirty channels fall into spcWriteStereo at $0C8C; others use its RET at
; $0CD2. DSP inhibit mask is $1A. See docs/audio.md for E2 evidence.
    .org $0C79
spcTickPanTransition:
    MOV A, $91+X
    BEQ testDirty
    MOV A, #$30
    MOV Y, #$03            ; Current word base $0330; X supplies channel offset.
    DEC $91+X
    CALL $0CD3             ; spcApplyPanStep: its OR replaces decrement flags.
testDirty:
    MOV A, $47
    AND A, $5E
    BEQ $0CD2              ; spcWriteStereo's RET, without producing DSP writes.
    ; Fall through to spcWriteStereo at $0C8C for this dirty channel.
