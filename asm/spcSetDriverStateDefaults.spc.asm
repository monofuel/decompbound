; Driver defaults tail, APU $2FC8..2FDC / file $262B0A..262B1E (21 bytes).
; Shared JMP/CALL entry, independent of DP. Writes exclusive lookup capacities
; for ports3/2/1 to $04D3/$04D2/$04D1, plus auxiliary default $04D4.
; Returns A=$C0,N=1/Z=0; preserves X/Y/C/H/V/P/I/B. No extra stack frame;
; RET consumes the original caller frame from $16A5 or a direct CALL.
; $04D0 is untouched here; startup's preceding clear establishes zero. The wider
; role of $04D4 remains open. TODO: identify the purpose of its $C0 default.
; Following bytes are outside this code source.
    .org $2FC8
spcSetDriverStateDefaults:
    MOV A, #$80
    MOV !$04D3, A
    MOV A, #$09
    MOV !$04D2, A
    MOV A, #$1D
    MOV !$04D1, A
    MOV A, #$C0
    MOV !$04D4, A
    RET
