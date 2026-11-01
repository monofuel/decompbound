; Arm master-factor countdown, APU $2E0B..2E10 / file $26294D..262952 (6B).
; CALL/RET: sets $0439=$69 without changing current/pending master state.
; Original port-one input 8 reaches this entry; preceding bytes are record data.
; Returns A=$69,N=0/Z=0; preserves X/Y/C/H/V/P/I/B, DP-independent.
; TODO: identify the broader trigger role; no port writes. See docs/audio.md.
    .org $2E0B
spcArmMasterFactorF0:
    MOV A, #$69
    MOV !$0439, A
    RET
