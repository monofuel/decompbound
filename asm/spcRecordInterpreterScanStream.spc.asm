; Record stream scan, APU $0FB7..1067 / file $260AF9..260BA9 (177 bytes).
; CALL/shared entry, DP zero; $2E=port,$2F=2*port,$2A/$2B=seven-byte state.
; Calls $13A0 once; Z=0 returns through shared RET $0FB6, Z=1 scans tokens.
; Stream base is $0480+2*port; cursor $D0+port is
; a BYTE, token address P+((cursor+6)&255), cursor advances modulo256.
; Zero tails to restored-channel finish $1491; positive tokens select timing; E0/E1/ED consume
; instrument/pan/gain operands, C9 marks/returns, other negative bytes produce
; raw pitch. ED with old control zero returns clearing marker instead of gain.
; Operand cursor wrap can fall through to readPan; no script bounds validation.
; Timing-prefix-only byte windows can cycle without returning. Token grammar
; below assumes record/state do not alias scratch or the native caller frame.
; Uses record helpers/voice DSP tails, native stack and DP $10..$23/$47;
; musical identities, valid input domains and absolute cadence remain open. See docs/audio.md.
    .org $0FB7
spcRecordInterpreterScanStream:
    CALL $13A0
    BNE $0FB6             ; Shared selector RET, not a loop back to this CALL.
    MOV A, $2A
    INC A
    INC A                 ; Low-byte-only +2; no carry into state pointer high.
    MOV Y, $2B
    CALL $0F3C            ; Restore state bytes 2..4 as instrument/gain/control.
    INC Y
    MOV A, [$20]+Y        ; State byte six: raw pitch fractional input.
    MOV !$04DE, A
readNextToken:
    MOV A, $D0+X
    CLRC
    ADC A, #$06
    MOV Y, A
    INC $D0+X
    MOV X, $2F
    MOV A, $0480+X
    MOV $20, A
    INC X
    MOV A, $0480+X
    MOV $21, A
    MOV A, [$20]+Y
    MOV $22, A
    BEQ endRecord
    MOV X, $2E
    AND A, #$80
    BEQ selectTiming
    MOV A, $22
    CMP A, #$E0
    BEQ readInstrument
    CMP A, #$C9
    BEQ storeMarker
    CMP A, #$E1
    BEQ readPan
    CMP A, #$ED
    BEQ readGain
    MOV Y, $22
    MOV A, #$00
    MOV $04C8+X, A
    MOV A, !$04DE
    JMP $10E7             ; Raw YA position, not the compensated event-pitch entry.
endRecord:
    JMP $1491             ; Restore saved channel fields, release the slot and RET.
selectTiming:
    CALL $0FA1
    MOV A, !$04D8
    MOV $04BC+X, A
    MOV A, !$04D9
    MOV $04C0+X, A
    JMP readNextToken
readInstrument:
    INC Y
    MOV A, [$20]+Y
    CALL $1130
    MOV X, $2E
advanceOperand:
    INC $D0+X
    BNE readNextToken
    ; A wrapped operand cursor falls through, using the helper's returned Y.
readPan:
    INC Y
    MOV A, [$20]+Y
    MOV $23, A
    MOV A, !$04DB
    MOV $22, A
writePanAndGain:
    MOV A, !$04DF
    MOV X, A
    CALL $10B6
    MOV Y, $2E
    MOV A, #$08
    MUL YA
    MOV X, A
    MOV A, $23
    MOV $0464+X, A
    MOV !$04DC, A
    MOV A, $22
    MOV $0463+X, A
    MOV !$04DB, A
    MOV X, $2E
    JMP advanceOperand
readGain:
    INC Y
    MOV A, [$20]+Y
    MOV $22, A
    MOV A, !$04DC
    MOV $23, A
    BNE writePanAndGain
storeMarker:
    MOV $04C8+X, A         ; C9 stores C9; zero-control ED stores zero and returns.
    RET
