; Held-event lookahead, APU $0CF7..0D5F / file $260839..2608A1 (105 bytes).
; Shared entry: DP zero, X=even channel offset 0..14; mask $47, inhibit $1A.
; Nonzero $71+X decrements, then scans if it reached zero or $70+X equals two.
; Scans through scratch pointer $14/$15, byte index Y and private count $17;
; live cursor $30/$31+X, count $80+X and software target/return remain unchanged.
; Preserves X, PSW P/I/B and balanced native SP on finite paths; clobbers A/Y,
; flags and $14/$15/$17. May directly write guarded DSP KOFF, not queued $46.
; Finite exits join $0D60 transition update; unchecked streams can cycle or wrap.
; See docs/audio.md for scan grammar and the separate advancing fetch.
    .org $0CF7
spcLookAheadSequence:
    MOV A, $71+X
    BEQ $0D60
    DEC $71+X
    BEQ beginScan
    MOV A, #$02
    CBNE $70+X, $0D60

beginScan:
    MOV A, $80+X
    MOV $17, A             ; Repeat decisions consume this private copy only.
    MOV A, $30+X
    MOV Y, $31+X
setScanPointer:
    MOVW $14, YA
    MOV Y, #$00
scanByte:
    MOV A, [$14]+Y
    BEQ zeroControl
    BMI classifyToken

skipPrefix:
    INC Y
    BMI requestKeyOff      ; Stop if the incremented byte index has bit 7 set.
    MOV A, [$14]+Y
    BPL skipPrefix         ; Includes zero bytes here, unlike scanByte's zero case.
classifyToken:
    CMP A, #$C8
    BEQ $0D60              ; This token suppresses the lookahead key-off request.
    CMP A, #$EF
    BEQ followTarget
    CMP A, #$E0
    BCC requestKeyOff

    PUSH Y
    MOV Y, A
    POP A
    ADC A, $0B41+Y         ; CMP #$E0 left carry=1: index += metadata + opcode byte.
    MOV Y, A               ; Index wraps modulo 256; FF reads past metadata layout.
    BRA scanByte

zeroControl:
    MOV A, $17
    BEQ requestKeyOff
    DEC $17
    BNE repeatTarget
    MOV A, $0231+X
    PUSH A
    MOV A, $0230+X
    POP Y
    BRA setScanPointer
repeatTarget:
    MOV A, $0241+X
    PUSH A
    MOV A, $0240+X
    POP Y
    BRA setScanPointer

followTarget:
    INC Y
    MOV A, [$14]+Y
    PUSH A
    INC Y
    MOV A, [$14]+Y
    MOV Y, A
    POP A
    BRA setScanPointer     ; Follow EF's target only; do not read its count/push state.

requestKeyOff:
    MOV A, $47
    MOV Y, #$5C
    CALL $0741             ; Direct KOFF write iff ($47 & $1A)==0, including mask zero.
    ; Fall through $0D60: spcTickPitchTransition, with the caller's frame intact.
