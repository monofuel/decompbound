; Native immediate setter, APU $2C92..2C96 (5 bytes).
; Original port-one native dispatch; set master integer to 100, fraction zero.
; Shared callee preserves the caller frame and pending transitions/dirty state.
; Returns A=0,Y=value,X preserved,N=0/Z=1. C/H/V/P/I/B preserved; DP zero.
; Preceding three-byte record header remains copied data; no hardware I/O.
    .org $2C92
spcSetMaster100NativeAdapter:
    MOV A, #$64
    JMP $162E             ; Original stream-free global setter.
