; Native target selector, APU $2CDA..2CE2 (9 bytes).
; Original port-one command $09 arrives through kind-eight native dispatch.
; Select five target bytes at $2CAF, then share spcApplyNativeControlFades.
; Target payload and preceding three-byte header remain copied data. Local
; registers/flags/frame are unchanged; the shared helper owns later effects.
    .org $2CDA
spcNativeControlFadeTargets1:
    MOV $22, #$AF
    MOV $23, #$2C
    JMP $2D37
