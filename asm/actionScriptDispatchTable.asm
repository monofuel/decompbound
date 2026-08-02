; actionScriptDispatchTable
; Ported from snes_src/action_script_tables.nim :: actionScriptDispatchTable (evidence-preserving re-port).
;
; Entity action-script VM dispatch tables (bank $C0).
;
; Reverse-engineered structure (docs/scripts.md): low path `$C09558` is 77
; little-endian code pointers (`X = opcode * 2`); high path `$C095E2` overlays
; the last 8 low-path words. Companion tables `$C08C65`, `$C0A1AE`, `$C0A350`
; are additional static jump tables already used as convert_all seeds.
;
; Declared as project data (like header/vectors): pointers into our decompiled
; code, not copyrighted script *content*. Gold-gated via the region registry.
;
;
; --- actionScriptDispatchTable ---
; Emit the 77-entry action-script low-path dispatch table at file 0x9558.
; Targets verified against gold (same list as resolved_entries seeds).
; Emit the 77-entry action-script low-path dispatch table at file 0x9558.
; Targets verified against gold (same list as resolved_entries seeds).
;
; Named constants (values inlined below; names preserved as comments):
;   ActionScriptDispatchOffset = $9558
;   ActionScriptDispatchSnes = $C09558
;   ActionScriptDispatchLen = $9A
;     77 entries × 2 bytes (opcodes 0x00–0x4C low path).
;   JmpTable8C65Offset = $8C65
;   JmpTable8C65Len = $08
;   JmpTableA1AEOffset = $A1AE
;   JmpTableA1AELen = $20
;     Four word+pad pairs (8 words) = 32 bytes.
;   JmpTableA350Offset = $A350
;   JmpTableA350Len = $10
;     Eight code pointers.
;
.byte $F2, $95, $03, $96, $27, $96, $4D, $96, $85, $96, $AA, $96, $C3, $96, $DD, $99
.byte $1A, $9A, $2E, $9A, $5D, $99, $6B, $99, $C3, $99, $9F, $9A, $E2, $9A, $09, $9B
.byte $79, $99, $9E, $99, $0F, $9B, $0E, $9A, $87, $9A, $1F, $9B, $2C, $9B, $44, $9B
.byte $5C, $9A, $49, $96, $58, $96, $6F, $96, $4D, $9B, $61, $9B, $6B, $9B, $79, $9B
.byte $91, $9B, $B4, $9B, $E4, $9B, $EE, $9B, $20, $96, $F8, $9B, $CC, $9B, $97, $9A
.byte $E3, $96, $F3, $96, $03, $97, $A0, $98, $AE, $98, $BC, $98, $6D, $97, $92, $97
.byte $B7, $97, $DC, $97, $EF, $97, $02, $98, $26, $98, $4A, $98, $75, $98, $CA, $98
.byte $DE, $98, $F2, $98, $1C, $99, $CF, $96, $38, $9A, $3E, $9A, $44, $9A, $13, $97
.byte $31, $97, $4F, $97, $3D, $99, $31, $99, $A9, $9B, $CF, $96, $38, $9A, $3E, $9A
.byte $44, $9A, $13, $97, $31, $97, $4F, $97, $3D, $99
