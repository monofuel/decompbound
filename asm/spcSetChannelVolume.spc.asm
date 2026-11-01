; Set channel volume, APU $0A86..$0A8E / file $2605C8..$2605D0 (9 bytes).
; CALL/RET or command ED dispatch: A=full unsigned volume, even X in 0..14.
; Either direct page works. Writes integer $0301+X and clears fraction $0300+X.
; Preserves X/Y and PSW except N/Z; returns A=0, N=0, Z=1.
; Does not cancel counter $90+X, alter its step/target or dirty mask, or write
; DSP ports. See docs/audio.md for the channel-gain consumer and transition.
    .org $0A86
spcSetChannelVolume:
    MOV $0301+X, A
    MOV A, #$00
    MOV $0300+X, A
    RET
