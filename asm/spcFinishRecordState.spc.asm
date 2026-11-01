; Record progress/finish, APU $148B..14DE / file $260FCD..261020 (84B).
; CALL/shared entry: DP zero, slot $2E, even channel $04DF, caller frame live.
; $148B calls $13A0 and returns while its A!=0; zero enters finish $1491.
; Finish releases mask bits, restores saved gain/phase and current instrument,
; then clears slot state/kind and queues KOFF. Real stereo/instrument helpers
; honor the combined $47&$1A guard; no blanket zero-port contract applies.
; Finish returns X=slot,A=pending KOFF,N/Z from A; the nonfinish wrapper returns
; the progress helper's nonzero A. Helpers own scratch/Y/other
; arithmetic flags; P/I/B and the original native caller frame survive.
    .org $148B
spcProgressRecordState:
    CALL $13A0             ; Original record-progress helper; zero requests finish.
    BEQ spcFinishRecordState
    RET

spcFinishRecordState:
    MOV A, !$04DF
    MOV X, A
    MOV A, $1A
    AND A, !$04D6
    MOV $1A, A
    MOV A, $47
    OR A, !$04D7
    MOV $47, A
    MOV A, $5E
    OR A, !$04D7
    MOV $5E, A
    MOV A, $04E0+X
    MOV $0321+X, A
    MOV A, $04F0+X
    MOV $0351+X, A
    CALL $0C86             ; Dirty test and real stereo output with restored fields.
    MOV A, !$04DF
    MOV X, A
    MOV A, $1A
    AND A, !$04D6
    MOV $1A, A
    MOV A, $0211+X
    CALL $0962             ; Instrument-selector interior: do not replace $0211+X.
    MOV X, $2E
    MOV A, #$00
    MOV $04B4+X, A
    MOV $04C8+X, A
    MOV $048C+X, A
    MOV A, $46
    OR A, !$04D7
    MOV $46, A
    RET
