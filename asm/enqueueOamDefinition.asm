; Long-call wrapper and near dispatch into the four OAM queue appenders.
; File $008C54..$008C64, SNES $C08C54; 17 bytes. Jump table $C08C65 is
; adopted separately as jmpTable8C65.asm and is not part of this span.
; JSL $C08C54: JSR near entry then RTL. JMP/JSR $8C58 is the near entry
; used by enqueueEntityFrame. Native indices required: PHX then 16-bit PLA
; recover origin X. Forces M16 and does not force X16.
; A is the definition pointer, X origin X, Y origin Y, word $000B the bank
; (enqueue copies it 16-bit, so $000C rides along). Word $2400 selects
; queue 0..3 via ASL/TAX into JMP ($8C65,X). Valid indices and the 32-record
; capacity are not checked. The selected appender RTS returns to the near
; caller's caller for a JMP entry, or to the RTL for a JSL entry.
; Tests: integration_oam_publish.nim (JSL wrapper),
; integration_entity_sprite.nim (JMP from $A0FA).
.a16
.i16
JSR enqueueOamNear
RTL
enqueueOamNear:
REP #$20
.a16
PHX
PHA
LDA $2400
ASL A
TAX
PLA
JMP ($8C65,X)
