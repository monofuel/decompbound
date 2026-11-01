; Position-change song update, file $003C25..003C4A / SNES $C03C25 (38B).
; Native JSR/RTS in C0, decimal clear, DBR=$7E; position words $9877/$987B.
; $5DDA=1 suppresses lookup's port-one notification. If candidate $5DD6 differs
; from current $5DD4, call $C08756 then $C069AF (candidate consumer/loadSong).
; Finish with $5DDA=0. Requires writable nested DP frames and native stack;
; lookup and downstream callees clobber A/X/Y/flags. This wrapper does not
; preserve a prior $5DDA value or override lookup/consumer inhibition $5DD8.
    .a16
    .i16
updatePositionSongSelection:
    REP #$31
    LDA #$0001
    STA $5DDA
    LDX $987B
    LDA $9877
    JSL $C068F4             ; Resolve candidate and record pointer without notification.
    LDA $5DD6
    CMP $5DD4
    BEQ positionSongSelectionDone
    JSL $C08756             ; External pre-load helper; broader effects remain separate.
    JSL $C069AF             ; Consume the produced candidate/record if not inhibited.
positionSongSelectionDone:
    STZ $5DDA
    RTS
