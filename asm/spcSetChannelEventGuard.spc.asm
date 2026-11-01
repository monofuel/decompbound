; FC channel-event guard, APU $0B79..$0B7D / file $2606BB..$2606BF (5 bytes).
; Dispatcher or CALL/RET: X=even channel offset, stores (A+1) mod 256 at $0400+X.
; Dispatch has metadata zero, so A=0 becomes 1 without consuming an operand.
; Direct A=$FF stores zero. Direct entry is DP-independent; dispatch needs DP zero.
; Preserves X/Y and C/H/V/P/I/B; returns A=stored byte with matching N/Z.
; Later event handling reads this field before accepted-event setup; no DSP writes.
; Evidence: docs/audio.md (channel event dispatch).
    .org $0B79
spcSetChannelEventGuard:
    INC A
    MOV $0400+X, A
    RET
