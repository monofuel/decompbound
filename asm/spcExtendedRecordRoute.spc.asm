; Extended record tail, APU $1288..12C6 / file $260DCA..260E08 (63B).
; Kinds $0E/$10 share this unchecked table target. DP zero, $20/$21=P;
; pop saved table-offset byte above caller frame. Read words P-3/-2 into $26
; and P-5/-4 into $28, wrapping pointers. Ordered reads/stores can observe
; earlier scratch writes when headers alias $20..$29. X=byte[P+5],
; $2C=byte[P+6], YA=P at CALL $14EE.
; That helper initializes slot state/control; zero combined control clears its
; effective pointer low byte. Finally YA=0 tails through $10FC to clear the
; slot pointer $0458+2*port and set $0454+port=1. Requires caller's valid
; $2A/$2B state pointer, $2D command, $2E port,$2F=2*port and $04D7 mask.
; Callees determine wider effects; no record bounds/type validation is added.
    .org $1288
spcExtendedRecordRoute:
    POP X
    MOV X, #$00
    DECW $20
    DECW $20
    MOV A, [$20+X]
    MOV $27, A
    DECW $20
    MOV A, [$20+X]
    MOV $26, A
    DECW $20
    MOV A, [$20+X]
    MOV $29, A
    DECW $20
    MOV A, [$20+X]
    MOV $28, A
    INCW $20
    INCW $20
    INCW $20
    INCW $20
    INCW $20             ; Restore P before reading forward parameters.
    MOV Y, #$05
    MOV A, [$20]+Y
    MOV X, A
    INC Y
    MOV A, [$20]+Y
    MOV $2C, A
    MOV A, $20
    MOV Y, $21
    CALL $14EE            ; Original slot-control/state initializer.
    MOV A, #$00
    MOV Y, #$00
    JMP $10FC             ; Original pointer/state setter consumes caller's RET.
