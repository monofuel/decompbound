; Host command/update gate, APU $07F9..0819 / file $26033B..26035B (33 bytes).
; CALL/shared-tail entry: DP zero, $00=sampled port zero, $08=previous input.
; Saves old input in Y, copies $00 to A/$08, then enters $07FF below.
; Preserves X/SP and H/V/P/I/B; owns no native frame or RET. Continuations
; use the caller's frame. Special bytes precede change detection: $F0 cleanup,
; $FF full reset, $F1 continues the current selection without comparing Y.
; Active continuation uses $0C as selection-reset countdown: zero starts a
; channel pass, one decrements to zero/global control, others decrement/reset.
; See docs/audio.md for entry-specific flag and history behavior.
    .org $07F9
spcUpdateSequence:
    MOV Y, $08
    MOV A, $00
    MOV $08, A

; Shared $07FF entry from $07F4: A is the command, Y is caller-supplied.
; Does not prepare/update history. Nonspecial comparison is Y versus RAM $00,
; not Y versus A: the sign-guard caller can supply different A and $00 values.
spcProcessHostCommand:
    CMP A, #$F0
    BEQ $0787              ; Shared cleanup: clear pending globals and queue KOFF.
    CMP A, #$F1
    BEQ testSelection
    CMP A, #$FF
    BEQ $07E4              ; Jump wrapper for full reset at $075E.
    CMP Y, $00
    BNE $07E7              ; Jump wrapper for selecting A at $0772.

testSelection:
    MOV A, $04
    BEQ $07E3              ; RET at the channel-reset tail when inactive.
    MOV A, $0C
    BEQ $0871              ; spcBeginChannelPass when no reset countdown remains.
    DBNZ $0C, $07A9        ; Preserve MOV's flags while decrementing the countdown.
    ; Fall through $081A: spcReadSequenceControl after count one becomes zero.
