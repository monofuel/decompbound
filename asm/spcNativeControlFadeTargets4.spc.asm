; Native target selector, APU $2CFE..2D06 (9 bytes).
; Original port-one command $0C arrives through kind-eight native dispatch.
; Select five target bytes at $2CBE, then share spcApplyNativeControlFades.
; Target payload and preceding three-byte header remain copied data. Local
; registers/flags/frame are unchanged; the shared helper owns later effects.
    .org $2CFE
spcNativeControlFadeTargets4:
    MOV $22, #$BE
    MOV $23, #$2C
    JMP $2D37
