; Tick global tempo, APU $08F6..0904 / file $260438..260446 (15 bytes).
; Fall-through entry/tail, direct page zero; no CALL/RET or stack accesses.
; Reached after channel commands in $07F9's normal active-$04 traversal.
; If duration $54 is nonzero, adds step $56/$57 to tempo $52/$53, decrements
; duration, and snaps to target $55*256 on the final tick. No channel-mask gate.
; Preserves X/SP and PSW P/I/B. Active: YA=result; C/H/V from ADDW, N/Z from
; result. Inactive: A=0, Y and C/H/V preserved, N=0/Z=1. Falls through $0905.
; Phase was produced at $05CD before this update; see docs/audio.md.
    .org $08F6
spcTickTempoTransition:
    MOV A, $54
    BEQ $0905              ; Zero duration leaves tempo and transition untouched.
    MOVW YA, $56
    ADDW YA, $52           ; Intermediate ticks accumulate modulo 65536.
    DBNZ $54, storeTempo
    MOVW YA, $54           ; Duration is now zero: YA = target $55, fraction zero.
storeTempo:
    MOVW $52, YA           ; Final tick snaps exactly, unlike the pan updater.
    ; Fall through $0905 to the other global transitions.
