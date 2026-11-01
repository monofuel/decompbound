; Port-zero adapter, APU $1184..1197 / file $260CC6..260CD9 (20 bytes).
; CALL/shared entry, DP zero; caller must supply $24/$25 lookup pointer.
; Selects state$0460,voice4/maskEF/bit10,parameter base40,then common $1207.
; Unlike ports1..3 it does not mask the copied input $04B0 to seven bits and
; does not initialize its pointer table. Actual capacity/data determine reachability.
; Shared lookup/native/continuation contracts apply; no local hardware access.
    .org $1184
spcRecordInterpreterPortZero:
    MOV $2A, #$60
    MOV $2B, #$04
    MOV X, #$00
    MOV A, #$EF
    MOV Y, #$10
    MOV $20, #$08
    MOV $21, #$40
    BNE $1207             ; Y=$10 established Z=0; stores do not change it.
