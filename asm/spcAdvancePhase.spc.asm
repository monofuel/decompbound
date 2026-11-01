; Advance timer/tempo phase, APU $05CD..05D7 / file $26010F..260119 (11 bytes).
; Shared branch/fall-through entry; direct page zero. Timer byte pushed at
; $057E must be atop hardware stack, from nonzero timer-0 read at $0579.
; Reads tempo $53 and phase $51; writes phase=(old+low(timer*tempo)) mod 256.
; A=new phase, Y=high(timer*tempo), X preserved; SP increments modulo 256.
; PSW N/Z/C/H/V reflect the low-product ADC; P/I/B preserved. MUL's high
; byte does not contribute to carry routing. This block does not CALL/RET.
; Carry falls through $05D8; no carry branches $05E0. See docs/audio.md.
    .org $05CD
spcAdvancePhase:
    MOV A, $53
    POP Y                  ; Recover count saved before the service-call path.
    MUL YA
    CLRC                   ; Deliberately discard all prior carry state.
    ADC A, $51             ; Add only the low product; high product stays in Y.
    MOV $51, A
    BCC $05E0              ; No carry: active $04 permits channel preview $0DD0.
    ; Carry falls through $05D8: CALL $07F9, then CALL $0625 at $05DB.
