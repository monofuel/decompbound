; Action-script counted loops; file $009603..009648, SNES $C09603..C09648.
; JSR/RTS entries in a matching ROM mirror; native M16/X16, WRAM DBR.
; DP+$8A is state offset, DP+$84 its work area ($15A2 + stateOffset*8),
; Y is stream cursor, and DP+$80 the long stream base. $12E6,X indexes bytes.
; Records contain a body-PC word and count byte; no bank, type or bounds checks.
; The final M16 count store also writes one byte beyond this three-byte record.
; Preserves D/DBR/widths/C/V; decimal unused; DP+$90/$94 scratch. See docs/scripts.md.

    .a16
    .i16
; Opcode $01: read count byte and push loop record, then continue at its body.
; Returns X=state, Y=entry Y+1 modulo 65536, A=new stack index; N/Z reflect Y.
actionScriptBeginLoop:
    ; The word read overreads the next body byte; only one byte is consumed.
    LDA [$80],Y
    LDX $8A
    INY

; Shared entry $9608: A=count/overread word, X=state, Y=body cursor.
; Same outputs as begin-loop, without fetching or incrementing the cursor.
pushLoopRecord:
    STA $90
    STY $94
    TYA
    LDY $12E6,X
    STA ($84),Y            ; Body PC; short indirect accesses use WRAM DBR.
    INY
    INY
    LDA $90
    STA ($84),Y            ; Count low byte; high byte spills into next record.
    INY
    TYA
    STA $12E6,X
    LDY $94
    RTS

; Opcode $24 at $9620: use low byte of state work register $1516 as count.
; No operand consumed; high work-register byte becomes the spill byte.
; Returns X=state, Y=input cursor, A=new stack index; N/Z reflect Y.
actionScriptBeginLoopFromWork:
    LDX $8A
    LDA $1516,X
    BRA pushLoopRecord

; Opcode $02 at $9627: decrement top count modulo 256; zero pops three bytes,
; otherwise retain index and jump to saved body PC. Initial count zero gives
; 256 iterations. Returns X=state, Y=next cursor, N/Z reflect Y; A=body PC on
; repeat or new stack index on exit. No empty-stack check: index zero wraps.
actionScriptEndLoop:
    STY $94
    LDX $8A
    LDY $12E6,X
    DEY
    SEP #$20
    LDA ($84),Y
    DEC A
    STA ($84),Y
    REP #$20               ; Preserve the byte DEC's Z flag for the branch.
    BNE repeatLoop

    DEY
    DEY
    TYA
    STA $12E6,X
    LDY $94                ; Exhausted: continue after the end-loop opcode.
    RTS

repeatLoop:
    DEY
    DEY
    LDA ($84),Y
    TAY
    RTS
