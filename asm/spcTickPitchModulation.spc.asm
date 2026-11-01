; Pitch modulation tail, APU $0D7C..0DCF / file $2608BE..260911 (84 bytes).
; Fall-through/shared entry: DP zero, X=channel, base pitch word $10/$11.
; Requires zero word $0E/$0F for signed offset; $13.7 requests base output.
; Uses current depth $B1, delay $02B0/$B0, ramp counter $0100, duration $02B1,
; saved depth $02C1, quotient $02C0 and phase/rate $02A0/$02A1, all indexed X.
; Preserves X, P/I/B and dirty mask $5E; clobbers A/Y/flags and DP $10..$12,
; $14..$17 through signed/conversion tails. $06BE converts/writes guarded pitch;
; skipped modulation reaches RET unless $13.7 requests output. See docs/audio.md.
    .org $0D7C
spcTickPitchModulation:
    MOV A, $B1+X
    BEQ testPitchOutput    ; Zero depth also freezes delay/ramp/phase progress.
    MOV A, $02B0+X
    CBNE $B0+X, advanceDelay

    MOV A, $0100+X
    CMP A, $02B1+X
    BNE advanceRamp
    MOV A, $02C1+X         ; Counter equality selects the saved target depth.
    BRA storeDepth
advanceRamp:
    SETP
    INC $00+X              ; Page-one direct access updates absolute $0100+X.
    CLRP
    MOV Y, A               ; Test the old counter, not the incremented value.
    BEQ addDepthStep        ; The first ramp update starts at zero depth.
    MOV A, $B1+X
addDepthStep:
    CLRC
    ADC A, $02C0+X
storeDepth:
    MOV $B1+X, A

    MOV A, $02A0+X
    CLRC
    ADC A, $02A1+X
    MOV $02A0+X, A
    MOV $12, A             ; Save phase bit 7 for signed addition at $0E41.
    ASL A
    ASL A
    BCC scaleDepth
    EOR A, #$FF            ; Phase bit 6 reflects the magnitude within a half-wave.
scaleDepth:
    MOV Y, A
    MOV A, $B1+X
    CMP A, #$F1
    BCC fractionalDepth
    AND A, #$0F
    MUL YA                 ; $F1..FF: full product with the low depth nibble.
    BRA addPitchOffset
fractionalDepth:
    MUL YA
    MOV A, Y               ; $00..F0: retain only the high product byte.
    MOV Y, #$00
addPitchOffset:
    CALL $0E41             ; Sign from $12.7; add magnitude to base word $10/$11.
convertPitch:
    JMP $06BE              ; Conversion and DSP output obey caller $47/$1A guard.

advanceDelay:
    INC $B0+X
testPitchOutput:
    BBS $13.7, convertPitch
    RET
