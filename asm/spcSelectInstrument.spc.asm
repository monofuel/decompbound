; E0 instrument selection, APU $095F..09B7 / file $2604A1..2604F9 (89 bytes).
; Dispatcher/RET: direct page zero, X=even channel offset 0..14, A=operand.
; Caller mask $47 selects guard bits at $1A and noise-enable bits at $49.
; Always stores operand at $0211+X and computes record pointer in DP $14/$15.
; Guarded: no record reads or further writes; A=mask intersection, Y=index*6
; high byte, C=0. Unguarded: four DSP writes, multiplier copy; A=record byte 5,
; Y=5, C=1. Preserves X and PSW P/I/B; N/Z reflect final A. Internal pushes
; are balanced; RET consumes caller return. H/V follow record-pointer ADC.
; No record bounds check. See docs/audio.md.
    .org $095F
spcSelectInstrument:
    MOV $0211+X, A         ; Preserve the original operand before remapping.
    MOV Y, A
    BPL directRecord
    SETC
    SBC A, #$CA
    CLRC
    ADC A, $5F             ; High-bit operand maps modulo 256 through base $5F.
directRecord:
    MOV Y, #$06
    MUL YA
    MOVW $14, YA
    CLRC
    ADC $14, #$00
    ADC $15, #$6E          ; Six-byte record address = $6E00 + index*6.

    MOV A, $1A
    AND A, $47
    BNE returnInstrument   ; Pointer/operand still change when writes are blocked.

    PUSH X
    MOV A, X
    XCN A
    LSR A
    OR A, #$04
    MOV X, A               ; DSP voice register base: voice*16 + SRCN offset 4.
    MOV Y, #$00
    MOV A, [$14]+Y
    BPL sampleRecord

    ; Select the shared DSP noise clock, retaining echo-write-disable bit 5.
    AND A, #$1F
    AND $48, #$20
    TSET1 !$0048           ; $48 = (old $48 & $20) | (record byte 0 & $1F).
    OR $49, $47            ; The regular flush publishes $49 to DSP NON.
    MOV A, Y               ; Y is zero: high-bit record writes SRCN=0.
    BRA writeRegister

sampleRecord:
    MOV A, $47
    TCLR1 !$0049           ; Ordinary record clears exactly the caller's mask bits.
loadRegister:
    MOV A, [$14]+Y
writeRegister:
    MOV !$00F2, X          ; Absolute DSPADDR, including the intended encoding.
    MOV !$00F3, A          ; SRCN, ADSR1, ADSR2, GAIN in that order.
    INC X
    INC Y
    CMP Y, #$04
    BNE loadRegister

    POP X
    MOV A, [$14]+Y
    MOV $0221+X, A         ; Record byte 4 is multiplier high byte.
    INC Y
    MOV A, [$14]+Y
    MOV $0220+X, A         ; Record byte 5 is multiplier low byte.
returnInstrument:
    RET
