; Update channel volume, APU $0C40..$0C78 / file $260782..$2607BA (57 bytes).
; CALL/shared tail from $0939: DP zero, even channel X in 0..14, mask $47.
; Advances nonzero transition counter $90+X and word $0300/$0301+X, updates
; modulation state, and recomputes gain $0321+X. Marks dirty channels in $5E.
; Preserves X; clobbers A/Y/PSW, fade scratch $14..$17, and stereo scratch
; $10..$12 when the downstream dirty-channel tail produces output.
; No direct DSP writes: continues into spcTickPanTransition at $0C79, whose
; shared stereo tail returns to the caller. See docs/audio.md for arithmetic.
    .org $0C40
spcTickChannelVolume:
    MOV A, $90+X
    BEQ testDepth
    MOV A, #$00
    MOV Y, #$03            ; Current volume word base $0300; X selects channel.
    DEC $90+X
    CALL $0CD3             ; spcApplyPanStep: OR-derived branch, no final snap.

testDepth:
    ; EB configures depth/rate/delay; accepted events reset counter and phase.
    MOV Y, $C1+X           ; Volume modulation depth; zero disables modulation.
    BEQ noModulation
    MOV A, $02E0+X         ; Delay threshold, compared with counter $C0+X.
    CBNE $C0+X, advanceDelay
    OR $5E, $47
    MOV A, $02D0+X         ; Modulation phase; bit 7 selects reflected half.
    BPL advanceWave
    INC Y
    BNE advanceWave
    MOV A, #$80            ; Depth $FF holds at phase $80 in the second half.
    BRA storeWave
advanceWave:
    CLRC
    ADC A, $02D1+X         ; Phase increment, wrapping modulo 256.
storeWave:
    MOV $02D0+X, A
    CALL $0E56             ; spcModulateChannelGain reflects phase and applies depth.
    BRA $0C79              ; Continue at spcTickPanTransition.

advanceDelay:
    INC $C0+X
noModulation:
    MOV A, #$FF            ; Delayed/disabled modulation uses factor 255, not 256.
    CALL $0E61             ; spcComputeChannelGain recomputes gain in either case.
    ; Fall through to spcTickPanTransition at APU $0C79.
