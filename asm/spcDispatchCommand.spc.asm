; Command dispatch, APU $0943..0954 / file $260485..260496 (18 bytes).
; CALL-style entry: A=command, X=channel pointer offset; caller return remains
; on stack. Pushes target high/low bytes for the shared $095E RET to consume.
; X and PSW P/I/B/H/V preserved; C=0. Either direct page works for fetch.
; Metadata nonzero: fetch one operand, A=Y=byte, cursor advances modulo 65536.
; Metadata zero: A=Y=0, cursor unchanged. N/Z reflect resulting A/Y.
; Dispatch leaves SP at entry value when handler starts; handler's RET returns
; to original caller. Targets/widths require valid tables. See docs/audio.md.
    .org $0943
spcDispatchCommand:
    ASL A                  ; Double command modulo 256 for the target-word index.
    MOV Y, A
    MOV A, $0B24+Y         ; Push high first, so RET pulls low then high.
    PUSH A
    MOV A, $0B23+Y
    PUSH A

    MOV A, Y
    LSR A                  ; Metadata index = command & $7F; this clears carry.
    MOV Y, A
    MOV A, $0BC1+Y
    BEQ $095D              ; Shared MOV Y,A / RET tail: dispatch without operand.
    ; Fall through $0955: advancing fetch, then shared RET into pushed target.
