; Tick temporary pitch/tempo state, APU $2DAB..2DC2 / file $2628ED..262904 (24B).
; CALL/RET or shared-tail entry: DP zero, countdown $0438; zero stays zero.
; Nonzero count decrements; expiry clears global pitch offset $50 via $1663,
; then tails to $163B's saved-tempo restore. Other ticks preserve X/Y/H/V/P/I/B,
; return A=count, C=1 and N/Z from count CMP zero. Native stack balances.
; Expiry with saved $0493!=0 restores tempo immediately. Saved zero instead
; uses inherited $20 as fade target; requires zero $0E/$0F and uses saved X=$44.
; TODO: identify the broader trigger policy for this countdown. See docs/audio.md.
    .org $2DAB
spcTickPitchTempoOverride:
    MOV A, !$0438
    CMP A, #$00
    BNE decrementOverride
returnOverride:
    RET

decrementOverride:
    DEC A
    MOV !$0438, A
    CMP A, #$00
    BNE returnOverride
    MOV A, #$00
    CALL $1663             ; Global pitch-offset adapter: $50=0.
    JMP $163B              ; Saved-tempo restore/fallback; its RET consumes our frame.
