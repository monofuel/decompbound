; Native target selector, APU $2D2E..2D36 (9 bytes).
; Original port-one command $10 arrives through kind-eight native dispatch.
; Select five target bytes at $2CD2, then share spcApplyNativeControlFades.
; Target payload and preceding three-byte header remain copied data. Local
; registers/flags/frame are unchanged; the shared helper owns later effects.
    .org $2D2E
spcNativeControlFadeTargets8:
    MOV $22, #$D2
    MOV $23, #$2C
    JMP $2D37
