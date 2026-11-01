; Tick echo volumes, APU $0905..$091D / file $260447..$26045F (25 bytes).
; Fall-through entry: DP zero, no CALL/RET or native stack access.
; Nonzero $68 adds steps $64/$66 to current words $60/$62, then decrements
; duration and snaps BOTH words to $69/$6A times 256 on the final tick.
; Preserves X/SP/P/I/B; active A/Y are right result, with C/H/V from its ADDW.
; Final N/Z reflect right target; inactive A=0, Y/C/H/V preserved, N=0/Z=1.
; Does not touch FLG, masks or DSP ports; continues $091E. See docs/audio.md.
    .org $0905
spcTickEchoVolumeTransition:
    MOV A, $68
    BEQ $091E              ; spcTickMasterVolumeTransition follows this fragment.
    MOVW YA, $64
    ADDW YA, $60
    MOVW $60, YA
    MOVW YA, $66
    ADDW YA, $62
    DBNZ $68, storeRightVolume
    MOVW YA, $68           ; Zero duration low byte plus left target high byte.
    MOVW $60, YA
    MOV Y, $6A
storeRightVolume:
    MOVW $62, YA
    ; Fall through to spcTickMasterVolumeTransition at APU $091E.
