; Driver state fill, APU $16A5..16C6 / file $2611E7..261208 (34 bytes).
; CALL entry from $050C with A=0 clears $0420..04FF and $E800..FEFF.
; Unchecked A!=0 instead fills with A, starting the high range at $E800+A.
; Uses selected-DP $24/$25, ending at $FF00; X/Y become0. Native frame must
; not alias those scratch bytes (page-one frames at SP=$22..24 do alias).
; JMPs to defaults $2FC8, whose real RET consumes the original caller frame.
; Full return A=$C0,C=1,N=1/Z=0; H/V/P/I/B preserved. No I/O access or CALL
; occurs here. Other RAM changes are limited to pointer scratch and the defaults;
; $FF00..FFFF is outside the fill.
    .org $16A5
spcClearDriverState:
    MOV X, #$20
fillAuxiliaryState:
    MOV $0400+X, A
    INC X
    CMP X, #$00
    BNE fillAuxiliaryState
    MOV Y, A              ; Startup zero starts at offset zero of the first page.
    MOV $24, #$00
    MOV $25, #$E8
fillHighState:
    MOV [$24]+Y, A
    INC Y
    CMP Y, #$00
    BNE fillHighState
    INC $25
    CMP $25, #$FF
    BNE fillHighState
    JMP $2FC8             ; spcSetDriverStateDefaults; no additional native frame.
