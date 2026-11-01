; Preview volume modulation, APU $0DD0..$0DDE / file $260912..$260920 (15 bytes).
; CALL/shared preview entry: DP zero, X=even channel offset, phase fraction $51.
; Clears $13.7; enables gain preview only for depth $C1+X != 0 and old delay
; counter $C0+X equal to threshold $02E0+X. Does not increment either counter.
; Enabled $0E49 sets $13.7 and updates derived gain $0321+X; disabled preserves it.
; Preserves X, P/I/B, phase/rate/depth/counters and dirty mask $5E; clobbers A/Y,
; flags and $13. No local port writes. Falls into pan preview $0DDF, which may
; use the request bit to emit stereo volume. See docs/audio.md.
    .org $0DD0
spcPreviewVolumeModulation:
    CLR1 $13.7
    MOV A, $C1+X
    BEQ previewPan
    MOV A, $02E0+X
    CBNE $C0+X, previewPan
    CALL $0E49             ; Neither the normal phase advance nor its depth-255 hold.
previewPan:
    ; Fall through to spcPreviewPan at $0DDF.
