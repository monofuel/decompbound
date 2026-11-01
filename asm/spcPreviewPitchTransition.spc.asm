; Preview a pitch transition, APU $0DFC..$0E12 / file $26093E..$260954.
; Shared preview entry after $0DD0 volume and $0DDF pan stages; DP zero,
; X=even channel offset, phase fraction $51, zero word $0E/$0F for signed math.
; Current $0360/$0361+X is copied to DP $10/$11. If count $A0+X is nonzero
; and delay $A1+X is zero, add trunc(signed16(step[$0370+X])*$51/256).
; Preserves X, P/I/B, persistent current/count/delay, dirty $5E and saved X $44.
; Clobbers A/Y/flags and DP $10..$15; $13.7 is cleared then set only on preview.
; Balanced calls, no local RET/ports; falls into $0E13. See docs/audio.md.
    .org $0DFC
spcPreviewPitchTransition:
    CLR1 $13.7
    CALL $0BBC             ; Preview always begins from the persistent current word.
    MOV A, $A0+X
    BEQ previewModulation
    MOV A, $A1+X
    BNE previewModulation  ; A pending delay is neither consumed nor previewed.
    MOV A, $0371+X
    MOV Y, A
    MOV A, $0370+X
    CALL $0E2B             ; Adds signed phase-scaled step; sets $13.7 even at phase 0.
previewModulation:
    ; Fall through to spcPreviewPitchModulation at $0E13.
