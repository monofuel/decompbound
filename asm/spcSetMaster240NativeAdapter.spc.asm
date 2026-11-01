; Native immediate setter, APU $2C9A..2C9E (5 bytes).
; Original port-one native dispatch; set master integer to 240, fraction zero.
; Shared callee preserves the caller frame and pending transitions/dirty state.
; Returns A=0,Y=value,X preserved,N=0/Z=1. C/H/V/P/I/B preserved; DP zero.
; Preceding three-byte record header remains copied data; no hardware I/O.
    .org $2C9A
spcSetMaster240NativeAdapter:
    MOV A, #$F0
    JMP $162E             ; Original stream-free global setter.
