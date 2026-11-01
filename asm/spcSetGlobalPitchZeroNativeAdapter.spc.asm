; Native immediate setter, APU $2CAA..2CAE (5 bytes).
; Original port-one native dispatch; set global raw pitch offset to zero.
; Shared callee preserves the caller frame and pending transitions/dirty state.
; Returns A=value,X/Y preserved,N/Z from value. C/H/V/P/I/B preserved; DP zero.
; Preceding three-byte record header remains copied data; no hardware I/O.
    .org $2CAA
spcSetGlobalPitchZeroNativeAdapter:
    MOV A, #$00
    JMP $1663             ; Original stream-free global setter.
