; OAM queue append dispatch, selected by word $2400 (queue index 0..3).
; File $008C65..$008C6C; SNES $C08C65. Four bank-$C0 near code pointers.
; enqueueOamDefinition doubles the index before JMP ($8C65,X).
; Targets: asm/appendOamQueues.asm. Queue layout: docs/graphics.md.
    .word $8C6D            ; Queue 0: appendQueue0, base $2404.
    .word $8C87            ; Queue 1: appendQueue1, base $2506.
    .word $8CA1            ; Queue 2: appendQueue2, base $2608.
    .word $8CBB            ; Queue 3: appendQueue3, base $270A.
