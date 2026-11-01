; Advance a delayed pitch transition, APU $0D60..$0D7B / file $2608A2..$2608BD.
; Shared normal-tick entry after $0CF7 lookahead; DP zero, X=even channel offset.
; Active count $A0+X and delay $A1+X are bytes. Delay postpones this tick even
; when its decrement reaches zero. Current/step/target are $0360/$0370/$0380+X.
; Preserves X, P/I/B and dirty mask $5E; clobbers A/Y/flags, DP $10/$11/$13
; and, on an update, $14..$17. No saved-X $44 dependency or local port writes.
; Always reads current into DP $10/$11, then falls into pitch modulation $0D7C.
; Its downstream signed-offset path requires zero word $0E/$0F. See docs/audio.md.
    .org $0D60
spcTickPitchTransition:
    CLR1 $13.7             ; Only a real transition update requests base pitch output.
    MOV A, $A0+X
    BEQ readCurrent
    MOV A, $A1+X
    BEQ advancePitch
    DEC $A1+X
    BRA readCurrent        ; The old nonzero delay consumes this whole tick.
advancePitch:
    SET1 $13.7
    MOV A, #$60
    MOV Y, #$03
    DEC $A0+X
    ; Enter AFTER $0CD3's dirty-mask OR, retaining DEC's Z through the setup.
    ; Remaining count zero snaps to target<<8; otherwise add the step modulo 16 bits.
    CALL $0CD6
readCurrent:
    CALL $0BBC             ; Always copy $0360/$0361+X, even when no update occurred.
    ; Fall through to spcTickPitchModulation at $0D7C; its RET owns the caller frame.
