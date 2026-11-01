; Native target selector, APU $2D16..2D1E (9 bytes).
; Original port-one command $0E arrives through kind-eight native dispatch.
; Select five target bytes at $2CC3, then share spcApplyNativeControlFades.
; This selector aliases the preceding selector's target row.
; Target payload and preceding three-byte header remain copied data. Local
; registers/flags/frame are unchanged; the shared helper owns later effects.
    .org $2D16
spcNativeControlFadeTargets6:
    MOV $22, #$C3
    MOV $23, #$2C
    JMP $2D37
