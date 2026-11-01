; Key off voices and enter IPL, APU $05FC..0624 / file $26013E..260166 (41 bytes).
; Jump/nonreturning-call entry: DP-independent, A/Y scratch, X preserved.
; Writes EVOLL/R=0, KOFF=$FF, EON=0, FLG=$20 through unconditional $0749.
; Then CONTROL=$80 disables all timers and maps IPL, before jumping to $FFC0.
; Leaves buffered shadows unchanged; no $1A/$1B inhibit checks apply.
; Calls balance SP; a caller's frame remains live at IPL handoff, with no RET.
; Final A=$80, Y=$6C, N=1/Z=0; C/H/V/P/I/B preserved. No port handshake
; or execution inside IPL is claimed by this fragment. See docs/audio.md.
    .org $05FC
spcReturnToIpl:
    MOV A, #$00
    MOV Y, #$2C
    CALL $0749             ; Clear hardware echo volumes without changing shadows.
    MOV Y, #$3C
    CALL $0749

    MOV A, #$FF
    MOV Y, #$5C
    CALL $0749             ; Key off every voice.
    MOV A, #$00
    MOV Y, #$4D
    CALL $0749             ; Clear per-voice echo enable.
    MOV A, #$20
    MOV Y, #$6C
    CALL $0749             ; Disable echo RAM writes; reset/mute bits are clear.

    MOV A, #$80
    MOV !$00F1, A          ; Map the real IPL and disable the three timer enables.
    JMP $FFC0              ; Nonreturning handoff; stop before IPL for bounded checks.
