; Tick record progress, APU $13A0..1419 / file $260EE2..260F5B (122B).
; CALL/RET: DP zero, $2E=slot (normally 0..3), $2F=twice slot, trusted state.
; Restore X from $2E, preincrement $04B8+X modulo 256. Limit $04BC+X resets
; matching progress to zero, except $FF becomes $FE. Limit $04C0+X may queue
; KOFF when $049C+X bit0 is clear; the OR's zero flag can also reset progress.
; First progress value 1 takes the mode/initialization path below. Return X=slot,
; A=current progress, N/Z from A; other registers/flags depend on the path/callees.
; TODO: identify the full policy of the mode/limit/init fields. See docs/audio.md.
    .org $13A0
spcTickRecordContinuation:
    MOV X, $2E
    MOV A, !$04B8+X
    INC A
    MOV !$04B8+X, A
    CMP A, #$01
    BEQ testFirstProgress
    CMP A, !$04BC+X
    BEQ resetProgress
    CMP A, !$04C0+X
    BNE returnProgress
    MOV A, !$049C+X
    AND A, #$01
    BNE returnProgress
    MOV A, $46
    OR A, !$04D7
    MOV $46, A
    BNE returnProgress     ; Uses OR flags; zero mask/queue falls through with A=0.

resetProgress:
    CMP A, #$FF
    BNE clearProgress
    MOV A, #$FE
    BNE storeProgress
clearProgress:
    MOV A, #$00
storeProgress:
    MOV !$04B8+X, A
returnProgress:
    MOV A, !$04B8+X
    RET

; $13D8 shared entry: X must already select the slot. Set mode $81 and enter
; initialization without incrementing progress; normal first-progress mode 1
; reaches this same block. Final return still reloads the current progress byte.
spcInitializeRecordContinuation:
    MOV A, #$81
    MOV !$049C+X, A
    BNE initializeProgress

testFirstProgress:
    MOV A, !$049C+X
    CMP A, #$01
    BEQ spcInitializeRecordContinuation
    CMP A, #$81
    BEQ returnProgress
initializeProgress:
    MOV A, !$0450+X
    BNE testQueuedStart
    INC A                 ; Only a zero initialization byte becomes one.
    MOV !$0450+X, A
    ; Original initializer takes payload at low-byte($2A+2), high byte $2B:
    ; there is no carry into the high pointer byte. It selects the instrument
    ; through $0962, replaces gain/phase and emits stereo/pitch for voice $04DF.
    ; It leaves $47=0, uses scratch $10..$17/$22/$23, and needs valid records/tables.
    CALL $1557            ; Apply state through the original instrument/stereo/pitch helpers.
    MOV X, $2E
    MOV A, !$0454+X
    BEQ testQueuedStart
    MOV X, $2F
    MOV A, !$0459+X
    MOV Y, A
    MOV A, !$0458+X
    CALL $110D            ; Original unconditional two-register YA writer.

testQueuedStart:
    MOV X, $2E
    MOV A, !$04C8+X
    BNE returnProgress
    MOV A, $45
    OR A, !$04D7
    MOV $45, A
    JMP returnProgress
