; Start an active transition, APU $0B94..$0BA3 (16 bytes), file $2606D6..$2606E5.
; F9 dispatch or held-service fall-through: DP zero, X=even channel offset,
; A=prefetched delay; [$30+X] now points to duration then raw target bytes.
; Stores delay $A1+X and duration $A0+X, fetches target and applies both offsets.
; The second ADC RETAINS first-sum carry. Shared $0BA4 masks target to seven
; bits, stores $0380+X, divides target-currentInteger into signed step $0370+X.
; Requires $44=entry X and zero word $0E/$0F; preserves current pitch and
; pending configuration. Returns via $0BBB with X=$44, A=Y=step high byte.
; Preserves P/I/B; clobbers N/Z/C/H/V and DP $12/$14/$15. No dirty-mask or
; port writes. The two further fetches make three F9 operands. See docs/audio.md.
    .org $0B94
spcStartActivePitchTransition:
    MOV $A1+X, A           ; Delay is installed directly, not the pending $0281 field.
    CALL $0955
    MOV $A0+X, A           ; Active duration zero is stored as-is, including divide-by-zero.
    CALL $0955
    CLRC
    ADC A, $50             ; First unsigned byte sum supplies carry to the next ADC.
    ADC A, $02F0+X         ; No second CLRC: unlike the accepted-event offset path.
    ; Fall through $0BA4: spcSetPitchTransitionTarget, including its shared RET.
