; Native target selector, APU $2D22..2D2A (9 bytes).
; Original port-one command $0F arrives through kind-eight native dispatch.
; Select five target bytes at $2CCD, then share spcApplyNativeControlFades.
; Target payload and preceding three-byte header remain copied data. Local
; registers/flags/frame are unchanged; the shared helper owns later effects.
    .org $2D22
spcNativeControlFadeTargets7:
    MOV $22, #$CD
    MOV $23, #$2C
    JMP $2D37
