; jmpTableA350
; Ported from snes_src/action_script_tables.nim :: jmpTableA350 (evidence-preserving re-port).
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
; --- jmpTableA350 ---
; Emit the 8-entry jump table at file 0xA350.
; Emit the 8-entry jump table at file 0xA350.
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
.byte $B7, $A2, $17, $A3, $E1, $A2, $17, $A3, $B7, $A2, $17, $A3, $E1, $A2, $17, $A3
