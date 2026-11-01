; Fetch an advancing channel byte, APU $0955..$095E / file $260497..$2604A0.
; CALL/RET: X selects pointer pair at DP $30+X; either direct page is valid.
; Returns the fetched byte in A and Y; advances the pointer modulo 65536.
; Preserves X and PSW except N/Z. See docs/audio.md for fetch evidence.
    .org $0955
spcSequenceFetch:
    MOV A, [$30+X]
    INC $30+X
    BNE returnByte
    INC $31+X              ; Carry a low-byte wrap into the pointer high byte.
returnByte:
    MOV Y, A
    RET
