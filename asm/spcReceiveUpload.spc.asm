; Host upload receiver, APU $0EE1..0F2C / file $260A23..260A6E (76 bytes).
; CALL/RET: DP zero, writable native frame, IPL unmapped for high-RAM uploads.
; Publish AA/BB on output ports0/1; wait for input0=CC, then read headers:
; input2/3=destination low/high, input0=token, input1=continue flag. Echo token.
; Nonzero flag receives bytes with modulo-256 token Y, starting at0; no length
; word exists. Two negative Y-input0 comparisons begin another header. Host
; must pace input/token changes; waits have no timeout or destination bounds.
; Writes DP14/15 and destination RAM, possibly code/stack/I/O if host requests.
; Final zero flag writes CONTROL=$31 and RETs: A=0,X=$31,Y=final header token;
; N=0/Z=0, C=last comparison, H/V/P/I/B preserved. Native frame balances.
    .org $0EE1
spcReceiveUpload:
    MOV A, #$AA
    MOV !$00F4, A
    MOV A, #$BB
    MOV !$00F5, A
waitHostReady:
    MOV A, !$00F4
    CMP A, #$CC
    BNE waitHostReady
    BRA readBlockHeader

waitFirstToken:
    MOV Y, !$00F4
    BNE waitFirstToken     ; Each continued block begins with input token zero.
waitNextToken:
    CMP Y, !$00F4
    BNE testHeaderToken
    MOV A, !$00F5
    MOV !$00F4, Y          ; Acknowledge before the actual RAM write.
    MOV [$14]+Y, A
    INC Y
    BNE waitNextToken
    INC $15               ; Advance base high byte when counter wraps; low stays fixed.
    BRA waitNextToken

testHeaderToken:
    BPL waitNextToken
    CMP Y, !$00F4          ; Require a second negative subtraction, not equal reads.
    BPL waitNextToken
readBlockHeader:
    MOV A, !$00F6
    MOV Y, !$00F7
    MOVW $14, YA
    MOV Y, !$00F4
    MOV A, !$00F5
    MOV !$00F4, Y
    BNE waitFirstToken     ; Flags still reflect the continuation byte in A.

    MOV X, #$31
    MOV !$00F1, X          ; Enable timer0, clear input ports, unmap IPL; no DSP writes.
    RET
