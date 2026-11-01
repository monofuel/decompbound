; Prepare event, APU $0654..0683 / file $260196..2601C5 (48 bytes).
; CALL-style entry: direct page zero, A=Y=event byte, X=even channel offset.
; Y>=$CA invokes instrument selection before inhibition testing, then Y=$A4.
; $C8/$C9 or nonzero ($1A & $47) return via $0653; instrument-side effects
; can precede the latter return. Accepted events set $0360/$0361+X and $02A0+X.
; Preserves X and PSW P/I/B; clobbers A/Y/flags. Instrument path also uses
; DP $14/$15, $48/$49 and DSP ports under $095F's own guard; see docs/audio.md.
; Accepted path falls through $0684 into spcResetEventState; no local RET.
    .org $0654
spcPrepareChannelEvent:
    CMP Y, #$CA
    BCC testEvent
    CALL $095F             ; Instrument selection uses original A, even if inhibited.
    MOV Y, #$A4            ; Continue with this replacement event after selection.
testEvent:
    CMP Y, #$C8
    BCS $0653              ; Shared RET: excludes $C8/$C9 before any event writes.
    MOV A, $1A
    AND A, $47
    BNE $0653              ; Instrument selection, if requested, already ran.

    MOV A, Y
    AND A, #$7F
    CLRC
    ADC A, $50             ; First independent wrapping byte offset.
    CLRC                   ; Discard first addition's carry before channel offset.
    ADC A, $02F0+X
    MOV $0361+X, A
    MOV A, $0381+X
    MOV $0360+X, A         ; Replace the fraction from this channel source byte.

    ; TODO: identify the downstream meaning of this source-bit/mode-bit mapping.
    MOV A, $02B1+X
    LSR A
    MOV A, #$00
    ROR A                  ; Map source bit 0 to bit 7; all other result bits zero.
    MOV $02A0+X, A
    ; At $0684: A=mode byte, C=0, N/Z from ROR; H/V from second offset ADC.
    ; Fall through $0684: spcResetEventState resets counters and marks dirty bits.
