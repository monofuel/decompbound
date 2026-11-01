; Position-change song-selection gate, file $04FD45..04FD4A / SNES $C4FD45 (6B).
; Native RTL entry; A is a full word, DBR selects the destination (normally $7E).
; Store A to $B549: zero disables the C05274 -> C03C25 selection path, nonzero
; enables it. C03CE5 supplies zero; initializeResidentApu supplies one separately.
; Force A/X16 and C=0; preserve A/X/Y/D/DBR and other status bits. Native frame
; balances. Changing this word neither loads a song nor resets cached positions.
    .a16
    .i16
setPositionSongSelectionEnabled:
    REP #$31
    STA $B549
    RTL
