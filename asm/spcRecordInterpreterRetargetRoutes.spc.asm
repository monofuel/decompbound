; Retarget preludes, APU $1170..117B / file $260CB2..260CBD (12 bytes).
; Shared record-kind entries: DP zero,$20/$21=P,native stack top=saved lookup
; offset from $1249. First retarget port-two table slot and queue byte via1152,
; then forward to the existing kind-six/kind-four setup route respectively.
; The route POP consumes the saved offset; its RET uses the service caller frame.
; Prefix metadata and stream body remain unmodified runtime data.
    .org $1170
spcRecordInterpreterRetargetMarked:
    CALL $1152
    JMP $1278
spcRecordInterpreterRetargetOrdinary:
    CALL $1152
    JMP $1270
