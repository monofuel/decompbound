; Start display-brightness transition, file $00886C..008879 / SNES $C0886C..C08879.
; JSL/RTL: native mode, any M/X widths, DP independent; writable DBR:$0028..2A.
; Destination bytes and native stack/frame must be disjoint.
; Store low A as brightness step and low X as countdown reload/current count.
; Preserves A, P, DP, DBR and native frame; truncates X/Y to low bytes even
; when PLP restores X16. To feed NMI's DP-zero consumer use bank-zero WRAM
; (DBR $00 or its low-WRAM mirrors, or $7E); other banks select other storage.
; NMI $C081F7..8225 decrements count only while step!=0, advances brightness
; on a negative decremented byte, and clears step at dark/bright saturation.
    .a16
    .i16
startDisplayBrightnessTransition:
    PHP
    SEP #$30
    .a8
    .i8
    STA $0028              ; Signed-byte brightness delta, consumed by NMI.
    STX $0029              ; Reload used after a countdown expires.
    STX $002A              ; First update uses the same delay as later updates.
    PLP
    RTL
