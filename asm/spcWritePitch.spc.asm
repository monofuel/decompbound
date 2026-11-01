; Write scaled pitch, APU $0733..$0740 / file $260275..$260282.
; CALL/shared tail: direct page zero; X is even channel offset 0..14.
; Input DP $16/$17 is the full word to write to voice PITCHL/PITCHH.
; $47 & $1A suppresses both writes. Preserves X and the input word;
; clobbers A/Y/C/N/Z. Falls into spcWriteDsp at $0741 for the high byte and
; its RET. High output is not masked to DSP's 14-bit pitch. See docs/audio.md.
    .org $0733
spcWritePitch:
    MOV A, X
    XCN A
    LSR A
    OR A, #$02             ; Even channel offset becomes voice*$10+2.
    MOV Y, A
    MOV A, $16
    CALL $0741             ; Guarded low-byte write, preserving A/X/Y.
    INC Y
    MOV A, $17
    ; Fall through to spcWriteDsp at APU $0741 for the high-byte write.
