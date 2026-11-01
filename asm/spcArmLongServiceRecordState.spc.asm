; Native long arm, APU $15E7..15F2 / file $261129..261134 (12B).
; DP zero; set mode byte $0492=2,countdown $0491=$70, then share $1600 fade
; setup: duration=$70,target=$10, current master unchanged. Negative division
; requires zero $0E/$0F; returns X=$44 independently of incoming X.
; Preceding three bytes remain record metadata.
    .org $15E7
spcArmLongServiceRecordState:
    MOV A, #$02
    MOV !$0492, A
    MOV A, #$70
    MOV !$0491, A
    BNE $1600             ; Shared tail in spcArmShortServiceRecordState.
