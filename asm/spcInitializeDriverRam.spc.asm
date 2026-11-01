; Driver startup clear, APU $0500..050B / file $260042..26004D (12 bytes).
; Boot/fall-through entry, not CALL/RET: accepts arbitrary registers and PSW.
; Selects direct page zero, resets hardware SP=$CF and clears $0000..00DF.
; Returns by falling through to $050C: A=0, X=$E0, Y unchanged, SP=$CF;
; PSW P=0, C=1, Z=1, N=0; H/V/I/B preserved. No stack-memory writes.
; Establishes the zero word $0E/$0F and initial phase $51 even from dirty RAM.
; $00E0..00FF remain untouched here. See docs/audio.md for startup evidence.
    .org $0500
spcInitializeDriverRam:
    CLRP
    MOV X, #$CF
    MOV SP, X
    MOV A, #$00
    MOV X, A

clearDirectPage:
    MOV (X)+, A
    CMP X, #$E0
    BNE clearDirectPage
    ; Fall through to $050C: CALL $16A5 continues driver initialization.
