; Fetch stream word, APU $0750..$075D / file $260292..$26029F (14 bytes).
; CALL/RET: pointer is DP $40/$41; either direct page works, entry Y ignored.
; Returns A=low byte, Y=high byte, advances pointer by two modulo 65536.
; Preserves X and PSW except N/Z, which reflect the HIGH byte, not the word.
; PUSH/POP A uses one internal hardware-stack byte; caller must keep stream
; data/pointer clear of live stack bytes. See docs/audio.md for control consumers.
    .org $0750
spcFetchSequenceWord:
    MOV Y, #$00
    MOV A, [$40]+Y
    INCW $40
    PUSH A
    MOV A, [$40]+Y
    INCW $40
    MOV Y, A               ; Select high-byte flags for the caller's branch.
    POP A                  ; Restore low byte without changing those flags.
    RET
