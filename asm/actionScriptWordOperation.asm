; Apply a word operation to an indexed entity-template field.
; File $009A87..$009ABC (54 bytes), SNES $C09A87; JSR/RTS opcode $14.
; Native M16/X16, decimal clear; DBR=$7E or matching low-WRAM mirror.
; [$80],Y operands: field byte, operation byte, immediate word (four bytes).
; DP+$88 is entity byte offset; field byte indexes $C09AF9 after doubling.
; Preserves D/DBR/widths; clobbers A/X/Y/flags, DP+$8C/$90, $0A5A/$0A5B.
; Returns A=result, X=2*operation, Y after operands (16-bit wrap). Field and
; operation indices are unchecked (defined 0..7 and 0..3). See docs/scripts.md.
    .a16
    .i16

actionScriptWordOperation:
    LDA [$80],Y
    AND #$00FF
    ASL A
    TAX
    LDA $C09AF9,X          ; Template field's base WRAM byte address.
    CLC
    ADC $88                ; Add doubled entity ID; no additional scaling.
    ; Logical operations retain this address ADC's V (as does state entry
    ; $9A97); addressed entry $9A9F instead retains its incoming V.
    BRA consumeAddressTail

; $009A97: JSR/RTS opcode $27, same widths/bank and result as $9A87.
; DP+$8A is state byte offset; address is $1516+stateOffset. Consumes only
; operation byte and immediate word (three bytes); no address operand.
actionScriptStateWordOperation:
    LDA #$1516
    CLC
    ADC $8A
    BRA prepareOperation

; $009A9F: JSR/RTS opcode $0D, same widths/bank and result as $9A87.
; Operands: target address word in DBR, operation byte, immediate word
; (five bytes). No entity/state index is used to construct this address.
actionScriptAddressedWordOperation:
    LDA [$80],Y
    INY
consumeAddressTail:
    INY                    ; Field path consumes one byte; address path two.

prepareOperation:
    STA $8C                ; 16-bit target pointer; target accesses use DBR.
    LDA [$80],Y
    AND #$00FF
    ASL A                  ; Clears carry regardless of preceding address ADC.
    TAX
    INY
    LDA [$80],Y
    STA $90                ; Full word immediate for the operation handler.
    INY
    INY
    LDA $C09ABD,X
    STA $0A5A
    ; JMP ($abs), unlike JMP ($abs,X), fetches its pointer from BANK ZERO.
    ; PBR stays unchanged. Target RTS consumes this handler's caller frame.
    JMP ($0A5A)
