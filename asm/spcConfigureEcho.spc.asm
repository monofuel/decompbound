; Configure echo, APU $0B0A..$0B2B / file $26064C..$26066D (34 bytes).
; Dispatcher/RET: DP zero, X=channel, $44=X, A=prefetched delay request.
; Calls delay helper, fetches feedback into shadow $4E and a FIR selector.
; Eight coefficients come from $0E88+((8*selector+k) mod 256), k=0..7;
; writes them directly to DSP $0F..$7F. No selector bounds check exists.
; Returns X=$44, A=Y=$8F; C=0/H=0/V=1, N/Z from restored X; P/I/B preserved.
; Helper/FIR writes bypass the per-voice $1A and processing $1B guards.
; Balances native stack; feedback stays buffered until flush. See docs/audio.md.
    .org $0B0A
spcConfigureEcho:
    CALL $0B2C             ; spcConfigureEchoDelay: may settle/reset echo hardware.
    CALL $0955             ; spcSequenceFetch: feedback shadow, not immediate EFB.
    MOV $4E, A
    CALL $0955             ; Full selector byte; only the low product byte is used.
    MOV Y, #$08
    MUL YA
    MOV X, A
    MOV Y, #$0F
writeCoefficient:
    MOV A, $0E88+X
    CALL $0749             ; Unconditional DSP writer; intentionally skips mask test.
    INC X
    MOV A, Y
    CLRC
    ADC A, #$10
    MOV Y, A
    BPL writeCoefficient
    MOV X, $44
    RET
