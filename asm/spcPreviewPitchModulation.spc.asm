; Preview pitch modulation, APU $0E13..$0E2A / file $260955..$26096C.
; Shared preview entry: DP zero, X=even channel offset, base pitch DP $10/$11,
; phase fraction $51, and zero word $0E/$0F for the shared signed addition.
; Uses depth $B1+X, delay counter $B0+X and threshold $02B0+X. Old counter
; equality enables preview; no persistent counter/depth/ramp/phase is changed.
; Preserves X, P/I/B, $13 (including output request), $44 and dirty mask $5E.
; Clobbers A/Y/flags and, through shared tails, DP $10..$12/$14..$17 and DSP.
; Disabled preview uses $0DCC's request-bit/RET path; enabled preview shares
; waveform/conversion at $0DAC. Both use the caller's frame. See docs/audio.md.
    .org $0E13
spcPreviewPitchModulation:
    MOV A, $B1+X
    BEQ $0DCC              ; Zero depth: output only if $13.7 already requested it.
    MOV A, $02B0+X
    CBNE $B0+X, $0DCC      ; Compare the old counter; preview does not advance it.
    MOV Y, $51
    MOV A, $02A1+X
    MUL YA
    MOV A, Y               ; floor(rate*phaseFraction/256), an unsigned byte.
    CLRC
    ADC A, $02A0+X         ; Add persistent phase modulo 256, without storing it.
    ; $0DAC saves this phase once in $12, applies bit-6 reflection/bit-7 sign,
    ; and scales current depth before conversion. It never changes $13 here.
    JMP $0DAC
