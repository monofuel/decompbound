; Native target selector, APU $2D0A..2D12 (9 bytes).
; Original port-one command $0D arrives through kind-eight native dispatch.
; Select five target bytes at $2CC3, then share spcApplyNativeControlFades.
; Target payload and preceding three-byte header remain copied data. Local
; registers/flags/frame are unchanged; the shared helper owns later effects.
    .org $2D0A
spcNativeControlFadeTargets5:
    MOV $22, #$C3
    MOV $23, #$2C
    JMP $2D37
