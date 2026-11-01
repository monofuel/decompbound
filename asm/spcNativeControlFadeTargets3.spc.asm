; Native target selector, APU $2CF2..2CFA (9 bytes).
; Original port-one command $0B arrives through kind-eight native dispatch.
; Select five target bytes at $2CB9, then share spcApplyNativeControlFades.
; Target payload and preceding three-byte header remain copied data. Local
; registers/flags/frame are unchanged; the shared helper owns later effects.
    .org $2CF2
spcNativeControlFadeTargets3:
    MOV $22, #$B9
    MOV $23, #$2C
    JMP $2D37
