; Resolve then load candidate, file $006A07..006A1A / SNES $C06A07 (20B).
; Native JSL/RTL, decimal clear, DBR=$7E; positions $9877/$987B.
; Lookup honors $5DD8 and can notify port one unless $5DDA suppresses it.
; Always feed resulting $5DD6 to loadSong, even when lookup was inhibited.
; Does not update $5DD4 or send record byte+3; loader can wait/upload.
; No local frame; inherit both callees' scratch/stack requirements and effects.
; D/DBR preserved by callees; A/X16, registers/flags follow loadSong.
    .a16
    .i16
resolveAndLoadCurrentPositionSong:
    REP #$31
    LDX $987B
    LDA $9877
    JSL $C068F4
    LDA $5DD6
    JSL $C4FBBD
    RTL
