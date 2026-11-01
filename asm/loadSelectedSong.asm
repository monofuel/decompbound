; Load existing selected candidate, file $0069ED..0069F6 / SNES $C069ED (10B).
; Native JSL/RTL, decimal clear, DBR=$7E; candidate word $5DD6 is trusted.
; Always call loadSong, regardless of $5DD8 or candidate/current comparison.
; Does not update $5DD4 or send selected record byte+3. Loader can wait/upload.
; No local frame; requires loader's writable/nonaliasing DP scratch and stack.
; D/DBR preserved by loader; registers/flags follow it, A/X16 on return.
    .a16
    .i16
loadSelectedSong:
    REP #$31
    LDA $5DD6
    JSL $C4FBBD
    RTL
