; Record state initialization, APU $14DF..1556 / file $261021..261098 (120B).
; CALL/shared entries: DP zero, YA=source, $2A/$2B=destination state pointer,
; slot $2E, command $2D and mask $04D7. Copy Y=0..6 in order using live DP
; pointers; overlap observes earlier writes, and scratch aliasing can redirect it.
; $14DF clears slot control/alternate flag; $14EE combines X with FLG shadow's
; high bits. Zero combined control clears the source LOW byte before copying.
; $14FC is the zero-control shared entry. No direct I/O writes; copied addresses
; are unchecked, so callers must keep the live pointers and native frame valid.
; Main paths return X=slot,Y=7,A=command,C=1,N/Z from A; H/V/P/I/B preserved.
; They set inhibit/queued-off bits, zero progress fields and preserve caller frame.
    .org $14DF
spcInitializeRecordState:
    MOVW $22, YA
    MOV A, #$00
    MOV X, $2E
    MOV $04CC+X, A
    MOV $04C8+X, A
    JMP copyRecordState

spcInitializeControlledRecordState:
    MOVW $22, YA
    MOV $24, X
    MOV A, $48
    AND A, #$E0
    OR A, $24
    MOV $48, A
    BNE storeRecordControl
spcInitializePlainRecordState:
    MOVW $22, YA          ; At zero-control fall-through, A=0, so source low becomes zero.
    MOV A, #$00
storeRecordControl:
    MOV X, $2E
    MOV $04CC+X, A
copyRecordState:
    CALL spcReadRecordStateLimits
    MOV $20, $2A
    MOV $21, $2B
    MOV Y, #$00
copyRecordByte:
    MOV A, [$22]+Y
    MOV [$20]+Y, A
    INC Y
    CMP Y, #$07
    BNE copyRecordByte
    MOV A, $1A
    OR A, !$04D7
    MOV $1A, A
    MOV A, $46
    OR A, !$04D7
    MOV $46, A
    MOV A, !$04D7         ; Original redundant read precedes the clears.
    MOV A, #$00
    MOV $04B8+X, A
    MOV $D0+X, A
    MOV $D4+X, A
    MOV $D8+X, A
    MOV $049C+X, A
    MOV $04B0+X, A
    MOV $0450+X, A
    MOV $0454+X, A
    MOV A, $2D
    MOV $04B4+X, A
    RET

; Shared $1547: $22/$23=source,X=slot. Store first two bytes as limits;
; returns Y=1,A=second byte, scratch $21=second byte,N/Z from A, other flags intact.
spcReadRecordStateLimits:
    MOV Y, #$00
    MOV A, [$22]+Y
    MOV $04BC+X, A
    INC Y
    MOV A, [$22]+Y
    MOV $21, A
    MOV $04C0+X, A
    RET
