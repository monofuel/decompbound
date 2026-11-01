; Native immediate setter, APU $2CA2..2CA6 (5 bytes).
; Original port-one native dispatch; set global raw pitch offset to 16.
; Shared callee preserves the caller frame and pending transitions/dirty state.
; Returns A=value,X/Y preserved,N/Z from value. C/H/V/P/I/B preserved; DP zero.
; Preceding three-byte record header remains copied data; no hardware I/O.
    .org $2CA2
spcSetGlobalPitch16NativeAdapter:
    MOV A, #$10
    JMP $1663             ; Original stream-free global setter.
