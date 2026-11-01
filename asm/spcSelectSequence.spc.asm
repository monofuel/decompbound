; Select global sequence, APU $0772..$0799 / file $2602B4..$2602DB (40 bytes).
; CALL/RET or stop-tail entry: DP zero, A=selection byte; always stores $04=A.
; A>=128 branches to $079A without table lookup or the resets below; no RET here.
; For A<128, uses word table $2E48+2*A as cursor $40/$41, sets $0C=2, clears
; $0491/$04B1/$04B5 and ORs ~inhibitMask($1A) into pending DSP KOFF mask $46.
; Positive path RET: X=2*A, Y=table high byte, A=~$1A; SP balances, P/I/B
; preserved, C/H/V=0, N/Z reflect the TSET1 comparison with the old $46.
; Queues key-off rather than writing DSP ports. See docs/audio.md.
    .org $0772
spcSelectSequence:
    MOV $04, A             ; Generic entry stores the argument, not always zero.
    CLRC
    ADC A, #$00
    BMI $079A              ; Alternate selection path remains outside this source.

    ASL A
    MOV X, A
    MOV A, $2E49+X
    MOV Y, A
    MOV A, $2E48+X

; Shared $0782 entry from the negative mapper: YA=cursor, raw $04 preserved.
; Store the cursor and selection-reset countdown, then queue key-off and RET
; through the existing frame. Preserves X/Y/C/H/V; A/N/Z follow key-off cleanup.
spcSetSequenceCursor:
    MOVW $40, YA
    MOV $0C, #$02          ; Reset countdown before the first global control fetch.

; Tail entry $0787 from FE: preserve selection/cursor/$0C and X/Y; clear the
; three global bytes and queue KOFF. Returns A=~$1A, N/Z from TSET1; unlike
; the full entry, preserves incoming C/H/V. RET consumes the existing frame.
spcQueueSequenceKeyOff:
    ; TODO: identify the complete host policies of countdown $0491 and $04B5.
    MOV A, #$00
    MOV $0491, A
    MOV $04B1, A           ; Discard the last copied host-port-one change.
    MOV $04B5, A

    MOV A, $1A
    EOR A, #$FF
    TSET1 !$0046           ; Pending mask reaches DSP KOFF in a later flush.
    RET
