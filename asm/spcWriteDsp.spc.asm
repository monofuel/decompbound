; Guard a DSP port write, APU $0741..$074F / file $260283..$260291.
; CALL/RET or pitch-writer fall-through: direct page zero, A=value, Y=register.
; Writes DSP address $00F2 then data $00F3 iff caller mask $47 & $1A is zero.
; Preserves A/X/Y and PSW except N/Z, which reflect the mask intersection.
; Caller supplies the mask independently of X/Y. See docs/audio.md.
    .org $0741
spcWriteDsp:
    PUSH A
    MOV A, $47
    AND A, $1A
    POP A                  ; POP preserves the mask test's flags.
    BNE returnDsp
    MOV !$00F2, Y          ; DSPADDR; absolute encoding is intentional.
    MOV !$00F3, A          ; DSPDATA.
returnDsp:
    RET
