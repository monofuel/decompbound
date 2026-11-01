; Reset accepted-event state, APU $0684..0695 / file $2601C6..2601D7 (18 bytes).
; Fall-through fragment after $0654's event filters: DP zero, even channel X.
; Clears bytes $B0+X/$0100+X plus modulation phase $02D0+X and counter $C0+X.
; ORs caller mask $47 into dirty mask $5E and pending byte $45.
; Preserves X/Y/SP and PSW except N/Z; returns A=0, N/Z reflect updated $45.
; No stack or DSP writes; continues at $0696. See docs/audio.md for filters.
; TODO: identify the broader roles of $B0/$0100 and the downstream $45 consumer.
    .org $0684
spcResetEventState:
    MOV A, #$00
    MOV $B0+X, A
    MOV $0100+X, A
    MOV $02D0+X, A         ; Accepted events restart the modulation waveform.
    MOV $C0+X, A           ; Reconfiguration alone does not reset this delay.
    OR $5E, $47
    OR $45, $47
    ; Fall through to the accepted-event continuation at $0696.
