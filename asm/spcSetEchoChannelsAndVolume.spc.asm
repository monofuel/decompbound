; Set echo shadows, APU $0ACF..$0AE1 / file $260611..$260623 (19 bytes).
; Dispatcher/RET: DP zero, X=channel, A=prefetched channel-enable mask.
; Fetches left/right bytes and stores current words $60/$61 and $62/$63 as
; byte*256; mask goes to $4A. Clears FLG shadow $48 bit 5, preserving other bits.
; Does not cancel transition $68 or change its targets/steps; no direct DSP writes.
; Preserves X/P/I/B/C/H/V; returns A=0, Y=right byte, N=0/Z=1.
; Regular flush/settling controls when shadows reach DSP. See docs/audio.md.
    .org $0ACF
spcSetEchoChannelsAndVolume:
    MOV $4A, A
    CALL $0955             ; spcSequenceFetch: left volume byte is returned in Y.
    MOV A, #$00
    MOVW $60, YA
    CALL $0955             ; spcSequenceFetch: right volume byte.
    MOV A, #$00
    MOVW $62, YA
    CLR1 $48.5             ; Allow echo writes in the eventual FLG shadow flush.
    RET
