; Advance channel pass, APU $08F0..$08F5 / file $260432..$260437 (6 bytes).
; Branch/fall-through entry: DP zero, even X in 0..14, one-hot $47=1<<(X/2).
; Adds two to X and shifts mask left. Nonzero mask branches to spcVisitChannel
; at $0878, which refreshes $44; last channel ends with X=$10, mask=0 and
; falls into spcTickTempoTransition at $08F6. This fragment leaves $44 unchanged.
; Preserves A/Y/SP and PSW P/I/B/H/V. C is old mask bit 7; N/Z reflect shifted
; mask. No CALL/RET, stack or port access. See docs/audio.md for channel passes.
    .org $08F0
spcNextSequenceChannel:
    INC X
    INC X
    ASL $47
    BNE $0878              ; spcVisitChannel uses the advanced X and one-hot mask.
    ; Fall through to spcTickTempoTransition at APU $08F6.
