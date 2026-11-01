; Fetch an advancing channel byte, APU $0955..$095E / file $260497..$2604A0.
; CALL/RET: X selects pointer pair at DP $30+X; either direct page is valid.
; Returns the fetched byte in A and Y; advances the pointer modulo 65536.
; Preserves X and PSW except N/Z. See docs/audio.md for fetch evidence.
    .org $0955
spcSequenceFetch:
    MOV A, [$30+X]

; CALL entry $0957: A=already-read byte, same X/DP pointer contract.
; Advance without rereading the stream; return A=Y=input byte and N/Z from it.
; Preserves X and other PSW bits. Held F9 service uses this to skip its opcode.
spcAdvanceSequenceCursor:
    INC $30+X
    BNE returnByte
    INC $31+X              ; Carry a low-byte wrap into the pointer high byte.
returnByte:
    MOV Y, A
    RET
