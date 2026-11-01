; Native short arm/shared fade, APU $15F6..1608 / file $261138..26114A (19B).
; DP zero; set $0492=1,$0491=$18, then duration=$18,target=$10. Shared $1600
; takes A=duration. Current master word and stream cursor stay unchanged;
; negative division needs zero $0E/$0F; returns X=$44 regardless of incoming X,
; with flags/YA from the shared divider.
; Preceding three bytes remain record metadata; native caller frame balances.
    .org $15F6
spcArmShortServiceRecordState:
    MOV A, #$01
    MOV !$0492, A
    MOV A, #$18
    MOV !$0491, A
spcArmServiceRecordStateFade:
    MOV $5A, A
    MOV A, #$10
    MOV $5B, A
    JMP $0A30             ; Master transition interior; no stream operand fetch.
