; Four OAM queue appenders selected by jmpTable8C65.
; File $008C6D..$008CD4, SNES $C08C6D; 104 bytes (4 x 26). RTS handlers.
; Native M16/X16. Entry from enqueueOamDefinition after PHX/PHA of origin X
; and definition pointer; A holds the definition pointer, Y the origin Y,
; and the stacked word is origin X. Word $000B is the definition bank.
; Each queue base is $2404 / $2506 / $2608 / $270A. Parallel word arrays:
; definition pointers at base+$00, origin X at base+$40, origin Y at base+$80,
; bank words at base+$C0. The word at base+$100 is a byte count, advanced by
; two per record, used as the next index. Capacity is 32 records by array
; spacing; this code does not check it. Counts are not cleared here.
; Tests: integration_oam_publish.nim, integration_entity_sprite.nim.
.a16
.i16
appendQueue0:
LDX $2504
STA $2404,X
PLA
STA $2444,X
TYA
STA $2484,X
LDA $000B
STA $24C4,X
INX
INX
STX $2504
RTS
appendQueue1:
LDX $2606
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
LDX $2708
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
LDX $280A
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
