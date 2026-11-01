; E5 master volume, APU $0A24..0A28 / file $260566..26056A (5 bytes).
; Dispatcher/RET: direct page zero; Y=prefetched value (also supplied in A).
; Writes global 8.8 master factor $58/$59 as Y*256; gain consumer $0E61
; uses only integer $59 in its first staged high-byte multiplication.
; Preserves pending transition $5A..$5D and dirty mask $5E: no cancellation
; or immediate dirty marking. Preserves X/Y and PSW C/H/V/P/I/B.
; Returns A=0, N=0, Z=1; no further fetch or DSP writes. See docs/audio.md.
    .org $0A24
spcSetMasterVolume:
    MOV A, #$00
    MOVW $58, YA           ; Clear fraction $58; set global integer factor $59.
    RET
