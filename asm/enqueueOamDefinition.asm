; Long-call wrapper and near dispatch into the four OAM queue appenders.
; File $008C54..$008C64, SNES $C08C54. Jump table $C08C65 is adopted
; separately as jmpTable8C65.asm. Native indices required: PHX then a
; 16-bit PLA recovers origin X. Forces M16 and does not force X16.
; A is the definition pointer, X/Y the origin; word $000B is its bank.
; Word $2400 selects queue 0..3; index and 32-record capacity are unchecked.
; Evidence: docs/graphics.md (queue-to-buffer publication).
    .a16
    .i16

enqueueOamDefinition:
    JSR enqueueOamNear
    RTL

enqueueOamNear:
    ; JMP/JSR $8C58. Appender RTS returns to this caller's caller on JMP,
    ; or to the RTL above on JSL.
    REP #$20
    .a16
    PHX
    PHA
    LDA $2400               ; Queue index 0..3.
    ASL A
    TAX
    PLA                     ; Definition pointer.
    JMP ($8C65,X)
