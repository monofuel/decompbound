; E2 pan transition, APU $09D6..09FC / file $260518..26053E (39 bytes).
; Dispatcher/RET: direct page zero, X=even channel offset 0..14, DP $44=X.
; A=duration already fetched; fetches one target byte through $0955.
; Requires DP $0E/$0F=0 for negative steps. Stores remaining count $91+X,
; effective target $0350+X and signed 8.8 step $0340/$0341+X; no DSP writes.
; Preserves position $0330/$0331+X and phase control $0351+X. Uses DP $20/$12
; and, for negative displacement, $14/$15. Returns X=DP $44, A=Y=step high
; byte; N/Z reflect that byte, other flags follow $0BC7. See docs/audio.md.
    .org $09D6
spcSetPanTransition:
    MOV $91+X, A           ; Persistent update count, zero disables updates.
    PUSH A
    CALL $0955             ; Fetch target into A/Y and advance channel pointer.
    MOV $20, A

    MOV A, $0431
    CMP A, #$00
    BEQ useTarget
    MOV $20, #$0A          ; Global override selects integer position ten.
useTarget:
    MOV A, $20
    MOV $0350+X, A         ; Full target byte; E1's five-bit mask is not used.
    SETC
    SBC A, $0331+X         ; Unsigned subtraction carry preserves the full sign.

    POP X                  ; Duration becomes divisor; $0BC7 restores channel X.
    CALL $0BC7             ; Signed displacement*256/duration; zero is not guarded.
    MOV $0340+X, A
    MOV A, Y
    MOV $0341+X, A
    RET
