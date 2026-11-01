; Arm master-factor countdown, APU $2DED..2DF2 / file $26292F..262934 (6B).
; CALL/RET: sets $043A=$28 without changing current/pending master state.
; Original port-one input 7 reaches this entry; preceding bytes are record data.
; Returns A=$28,N=0/Z=0; preserves X/Y/C/H/V/P/I/B, DP-independent.
; TODO: identify the broader trigger role; no port writes. See docs/audio.md.
    .org $2DED
spcArmMasterFactorA0:
    MOV A, #$28
    MOV !$043A, A
    RET
