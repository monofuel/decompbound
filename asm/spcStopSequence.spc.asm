; Stop selection tail, APU $07EA..$07F3 / file $26032C..$260335 (10 bytes).
; Branch/tail entry from zero global control word: DP zero, caller frame live.
; Writes APU output port $00F4=0, then enters spcSelectSequence with A=0.
; Consequently clears activity $04, loads table selection zero and queues KOFF
; for uninhibited voices via $46; no DSP key-off occurs directly in this tail.
; Remaining register/flag effects and RET belong to the $0772 positive path.
; See docs/audio.md; the port's broader handshake meaning remains unclaimed.
    .org $07EA
spcStopSequence:
    MOV A, #$00
    MOV !$00F4, A          ; CPU-facing APU output port, not a DSP register.
    MOV A, #$00
    JMP $0772              ; spcSelectSequence shares the caller's hardware RET.
