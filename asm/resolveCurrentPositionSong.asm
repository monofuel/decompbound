; Resolve current-position candidate, file $0069F7..006A06 / SNES $C069F7 (16B).
; Native JSL/RTL, decimal clear, DBR=$7E; read positions $9877/$987B.
; Lookup honors $5DD8 inhibition and may notify port one when $5DDA=0.
; Return A=$5DD6 (retained candidate if inhibited), N/Z from that word; A/X16.
; No local frame; inherit lookup's nested scratch/stack requirements and effects.
; D/DBR preserved; X/Y/C/V and other state follow the original lookup.
    .a16
    .i16
resolveCurrentPositionSong:
    REP #$31
    LDX $987B
    LDA $9877
    JSL $C068F4
    LDA $5DD6
    RTL
