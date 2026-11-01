; Basic record tails, APU $1270..1287 / file $260DB2..260DC9 (24B).
; Accepted lookup entries: DP zero, $20/$21=record pointer P; top stack byte
; is saved table offset, above the original two-byte caller frame. Each POPs
; it into X and loads YA=P, then JMPs without another frame. At handoff N/Z
; reflect pointer high; C/H/V/P/I/B preserved. Callees own later scratch/state.
    .org $1270
spcBasicRecordRouteKindFour:
    POP X
    MOV A, $20
    MOV Y, $21
    JMP $0F56             ; Copy record setup and initialize selected slot state.

spcBasicRecordRouteKindSix:
    POP X
    MOV A, $20
    MOV Y, $21
    JMP $0F4B             ; Same setup, then set slot $049C+port to one.

spcBasicRecordRouteKindsZeroTwo:
    POP X
    MOV A, $20
    MOV Y, $21
    JMP $14DF             ; Copy seven-byte record into per-port state; shared RET.
