; Tick master volume, APU $091E..092F / file $260460..260471 (18 bytes).
; Fall-through entry/tail: direct page zero, no CALL/RET or stack accesses.
; Nonzero duration $5A adds step $5C/$5D to current $58/$59, decrements the
; counter, and snaps to target $5B*256 on the final tick. Replaces $5E with
; $FF on every active tick, including the last; zero duration preserves $5E.
; Preserves X/SP and PSW P/I/B. Active: YA=result, C/H/V from ADDW and N/Z
; from result. Inactive: A=0, Y/C/H/V preserved, N=0/Z=1. Falls through $0930
; to channel updates; gain consumes $59 at $0E61. See docs/audio.md.
    .org $091E
spcTickMasterVolumeTransition:
    MOV A, $5A
    BEQ $0930
    MOVW YA, $5C
    ADDW YA, $58           ; Intermediate ticks accumulate modulo 65536.
    DBNZ $5A, storeMasterVolume
    MOVW YA, $5A           ; Zero remaining count plus target $5B: exact 8.8 snap.
storeMasterVolume:
    MOVW $58, YA
    MOV $5E, #$FF          ; Replace all dirty bits; independent of caller mask $47.
    ; Fall through $0930: active channels recompute gain and test stereo dirty bits.
