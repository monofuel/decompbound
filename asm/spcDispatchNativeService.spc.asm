; Native service record, APU $12C7..1319 / file $260E09..260E5B (83 bytes).
; Shared entry for kind eight: DP zero, $20/$21=P (record code entry),
; $2E=port,$2F=2*port; stack top is saved table BYTE offset from $1249.
; P-3/P-2 contain a little-endian continuation pointer, P-1 is raw kind eight.
; For ports 0..3 saves continuation at $0440+2*port, pops table offset into X,
; then jumps to record code through the ORIGINAL per-port pointer table.
; Native entry: A=continuation high,Y=table offset,X=table offset; C=port!=0,
; N/Z from A, H/V/P/I/B preserved. $20/$21=P-3,$22/$23=continuation.
; Native RET uses the original service caller frame; no implicit $131A call.
; Ports outside 1..3 use table $180D and slot $0440. See docs/audio.md.
    .org $12C7
spcDispatchNativeService:
    MOV X, #$00
    DECW $20
    DECW $20
    MOV A, [$20+X]
    MOV $23, A            ; Header high byte precedes kind.
    DECW $20
    MOV A, [$20+X]
    MOV $22, A
    POP X
    MOV A, $2E
    CMP A, #$03
    BEQ portThree
    CMP A, #$02
    BEQ portTwo
    CMP A, #$01
    BEQ portOne
    MOV A, $22
    MOV !$0440, A
    MOV A, $23
    MOV !$0441, A
    JMP [$180D+X]
portThree:
    MOV A, $22
    MOV !$0446, A
    MOV A, $23
    MOV !$0447, A
    JMP [$16C7+X]
portTwo:
    MOV A, $22
    MOV !$0444, A
    MOV A, $23
    MOV !$0445, A
    JMP [$17C5+X]
portOne:
    MOV A, $22
    MOV !$0442, A
    MOV A, $23
    MOV !$0443, A
    JMP [$17D5+X]
