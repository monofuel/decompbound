; Modulate gain, APU $0E56..$0E60 / file $260998..$2609A2 (11 bytes).
; CALL/shared tail: DP zero, even channel X in 0..14, A=unsigned wave phase.
; Depth is byte $C1+X. Reflects phase to triangular amplitude, then passes
; factor=255-floor(depth*triangle/256) into spcComputeChannelGain at $0E61.
; Triangle is 2*phase below 128, otherwise 511-2*phase. No state is advanced.
; Preserves X and PSW P/I/B/H/V; returns C=original phase bit 7, A=Y=gain.
; Gain $0321+X is written by the shared tail; RET belongs to $0E72.
; EB/EC set depth; the musical effect identity remains open. See docs/audio.md.
    .org $0E56
spcModulateChannelGain:
    ASL A
    BCC scaleDepth
    EOR A, #$FF            ; Reflect the second half without discarding carry.
scaleDepth:
    MOV Y, $C1+X
    MUL YA
    MOV A, Y
    EOR A, #$FF            ; Convert attenuation magnitude into gain factor.
    ; Fall through to spcComputeChannelGain at APU $0E61.
