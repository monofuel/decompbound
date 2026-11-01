; Prior-selection sign guard, APU $07F4..07F8 / file $260336..26033A (5 bytes).
; Callable entry, DP zero: read $08 into A. Nonnegative returns immediately;
; negative branches into command classifier $07FF, skipping its $07F9 prelude
; (no new $00 read/copy to $08, no Y=$08 setup). That continuation therefore
; receives A=$08 and incoming Y; its later effects belong to the classifier.
; Local X/Y/SP/C/H/V/P/I/B preserved until RET/branch; N/Z reflect $08.
    .org $07F4
spcResumePriorSelection:
    MOV A, $08
    BMI $07FF
    RET
