; Record continuation routes, APU $1348..139F / file $260E8A..260EE1 (88B).
; Native/shared-frame entries: DP zero; $2E=slot, $2F=2*slot, trusted record
; pointers/parameters from the host-service adapter. No local pointer bounds checks.
; Forwarders below add no frame; their external targets retain their own contracts.
; TODO: broader record/control meanings and external cleanup policy remain open.
; See docs/audio.md for the verified host-service record dispatch.
    .org $1348
spcForwardRecordContinuation:
    JMP $148B              ; External continuation; no local return guarantee.
spcForwardParsedRecordContinuation:
    JMP $0FB7              ; Original record parser, with the caller's existing frame.

; $134E: call progress helper $13A0; zero progress or token zero tails to $1491.
; Otherwise increment byte $D4+slot modulo 256; consume a byte from [$26]+Y
; only when it equals $2C, resetting D4 and postincrementing D0's byte index.
; Token $7F queues $46|$04D7, then tails to $1144 with A=0. Other tokens call
; $1124, preserving record index Y on the native stack, then optionally read
; [$28]+Y when $29!=0: replace $48 with its low five bits and OR $04D7 into $49.
; X/flags/scratch can change through original callees; data pointers are trusted.
spcAdvanceRecordContinuation:
    CALL $13A0             ; spcTickRecordContinuation: final N/Z follow returned count.
    BEQ finishRecord
    INC $D4+X
    MOV A, $D4+X
    CMP A, $2C
    BNE returnRecord
    MOV A, #$00
    MOV $D4+X, A
    MOV A, $D0+X
    MOV Y, A
    INC $D0+X
    MOV A, [$26]+Y
    CMP A, #$00
    BEQ finishRecord
    CMP A, #$7F
    BEQ releaseRecord
    PUSH Y
    CALL $1124             ; Original unconditional single-register writer.
    POP Y
    MOV A, $29
    BEQ returnRecord
    MOV A, [$28]+Y
    AND A, #$1F
    MOV $48, A
    MOV A, $49
    OR A, !$04D7
    MOV $49, A
returnRecord:
    RET

releaseRecord:
    MOV A, $46
    OR A, !$04D7
    MOV $46, A
    MOV A, #$00
    JMP $1144              ; Write zero to two registers, using our native return.
finishRecord:
    JMP $1491              ; Restore saved channel state and release this record slot.

; $1394 CALL/RET: X=slot, A=raw mode; only $049C+X changes. All flags/registers
; preserved; this direct store is DP-independent. No stream fetch or port access.
spcSetRecordContinuationMode:
    MOV !$049C+X, A
    RET

; $1398 CALL/RET: X=slot, A/Y=two raw limits. Store A in $04BC+X and Y in
; $04C0+X; return A=Y,N/Z from Y, preserving X/Y/C/H/V/P/I/B. DP-independent.
spcSetRecordContinuationLimits:
    MOV !$04BC+X, A
    MOV A, Y
    MOV !$04C0+X, A
    RET
