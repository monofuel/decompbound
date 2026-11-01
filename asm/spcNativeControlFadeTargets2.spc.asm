; Native target selector, APU $2CE6..2CEE (9 bytes).
; Original port-one command $0A arrives through kind-eight native dispatch.
; Select five target bytes at $2CB4, then share spcApplyNativeControlFades.
; Target payload and preceding three-byte header remain copied data. Local
; registers/flags/frame are unchanged; the shared helper owns later effects.
    .org $2CE6
spcNativeControlFadeTargets2:
    MOV $22, #$B4
    MOV $23, #$2C
    JMP $2D37
