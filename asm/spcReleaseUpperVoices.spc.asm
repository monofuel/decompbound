; Release upper voice slots, APU $1453..1486 / file $260F95..260FC8 (52 bytes).
; CALL/RET entries: DP zero. Full entry releases bits 5,6,7; individual entries
; below release one bit. Clear its inhibit bit $1A; set its pending-KOFF $46,
; current mask $47 and dirty mask $5E bits; clear corresponding $04B5/6/7.
; Returns A=0,N=0/Z=1; preserves X/Y/C/H/V/P/I/B and balances native calls.
; Other mask bits and slot state remain untouched; no immediate hardware I/O.
; Pending $46 reaches DSP KOFF during a later enabled flush. See docs/audio.md.
    .org $1453
spcReleaseUpperVoices:
    CALL releaseVoiceFive
    CALL releaseVoiceSix
    CALL releaseVoiceSeven
    RET

; $145D CALL/RET: same contract, bit 5 only, clearing $04B5.
releaseVoiceFive:
    CLR1 $1A.5
    SET1 $46.5
    SET1 $47.5
    SET1 $5E.5
    MOV A, #$00
    MOV !$04B5, A
    RET

; $146B CALL/RET: same contract, bit 6 only, clearing $04B6.
releaseVoiceSix:
    CLR1 $1A.6
    SET1 $46.6
    SET1 $47.6
    SET1 $5E.6
    MOV A, #$00
    MOV !$04B6, A
    RET

; $1479 CALL/RET: same contract, bit 7 only, clearing $04B7.
releaseVoiceSeven:
    CLR1 $1A.7
    SET1 $46.7
    SET1 $47.7
    SET1 $5E.7
    MOV A, #$00
    MOV !$04B7, A
    RET
