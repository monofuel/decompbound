; Four OAM queue appenders selected by jmpTable8C65.
; File $008C6D..$008CD4, SNES $C08C6D. RTS handlers, native M16/X16.
; Entry from enqueueOamDefinition after PHX/PHA of origin X and the
; definition pointer. A holds the pointer, Y origin Y, stacked word
; origin X. Word $000B is the definition bank. Counts are not cleared
; here; 32-record capacity is array spacing and is not checked.
; Evidence: docs/graphics.md (queue connection).
    .a16
    .i16

    ; Parallel word arrays at each queue base:
    ;   +$00 definition pointer, +$40 origin X, +$80 origin Y
    ;   +$C0 bank word (16-bit copy of $000B, so $000C rides along)
    ;   +$100 next-record byte index, advanced by two per record
    ; Bases $2404, $2506, $2608, $270A.

appendQueue0:
    LDX $2504               ; Queue 0 next-record byte index.
    STA $2404,X             ; Definition pointer.
    PLA
    STA $2444,X             ; Origin X.
    TYA
    STA $2484,X             ; Origin Y.
    LDA $000B
    STA $24C4,X             ; Definition bank word.
    INX
    INX
    STX $2504
    RTS

appendQueue1:
    LDX $2606               ; Queue 1 next-record byte index.
    STA $2506,X
    PLA
    STA $2546,X
    TYA
    STA $2586,X
    LDA $000B
    STA $25C6,X
    INX
    INX
    STX $2606
    RTS

appendQueue2:
    LDX $2708               ; Queue 2 next-record byte index.
    STA $2608,X
    PLA
    STA $2648,X
    TYA
    STA $2688,X
    LDA $000B
    STA $26C8,X
    INX
    INX
    STX $2708
    RTS

appendQueue3:
    LDX $280A               ; Queue 3 next-record byte index.
    STA $270A,X
    PLA
    STA $274A,X
    TYA
    STA $278A,X
    LDA $000B
    STA $27CA,X
    INX
    INX
    STX $280A
    RTS
