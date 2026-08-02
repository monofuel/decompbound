; actionScriptFetch
; Ported from snes_src/action_script_fetch.nim :: actionScriptFetch (evidence-preserving re-port).
;
; Entity action-script VM fetch / dispatch loop
; (file 0x009506 / SNES $C09506, 82 bytes through RTS at $C09557).
;
; One entity tick for the `[$80],Y` action-script interpreter documented in
; docs/scripts.md. Called via JSR from the entity walker at `$C094E9`. When
; the per-entity wait counter at `$1372,X` is nonzero the tick only DECs it;
; otherwise the loop loads the script PC/bank, fetches opcodes until a wait
; is scheduled, and dispatches through the low (`$C09558`) or high
; (`$C095E2`) jump table already adopted as data in action_script_tables.nim.
;
; ADOPTED into the region registry (adopted.nim); convert_all carves these
; 82 bytes out of the former enclosing span 0x009250-0x009557. Gold-gated by
; tests/test_regions.nim and tests/test_action_script_fetch.nim.
;
;
; --- actionScriptFetch ---
; Run one entity action-script tick: wait countdown or fetch/dispatch.
;
; Entry (JSR): DP `$8A` = entity slot. M is 16-bit (immediates are word-
; sized). Clobbers A/X/Y and the DP scratch used below.
;
; Control flow:
; 1. **Wait tick** — if `$1372,X` ≠ 0, DEC it and RTS (no stream advance).
; 2. **Setup** — load script PC from `$13FE,X` into Y, bank from `$148A,X`
; into DP `$82`, and `entity*8 + $15A2` into DP `$84`.
; 3. **Fetch loop** — `LDA [$80],Y / INY / AND #$00FF`. Opcode byte is
; consumed before the handler runs; handlers see only operands at Y.
; 4. **Low path** (`opcode < $70`) — `ASL / TAX / JSR ($9558,X)`.
; 5. **High path** (`opcode >= $70`) — low nibble → `$1372,X` (inline wait),
; high nibble `AND #$70 / LSR×3 / TAX / JSR ($95E2,X)`.
; 6. After dispatch, if `$1372,X` is still 0, fetch the next opcode;
; otherwise save Y/`$82` back to `$13FE,X` / `$148A,X`, DEC wait, RTS.
;
; Evidence: gold disasm `code_bank00` `$C09506..$C09557`; dispatch tables
; gold-gated in action_script_tables.nim; operand widths for ops $06/$19/$42
; in docs/scripts.md.
;
; Named constants (values inlined below; names preserved as comments):
;   ActionScriptFetchOffset = $9506
;   ActionScriptFetchSnes = $C09506
;   ActionScriptFetchLen = $52
;   ActionScriptLowDispatch = $9558
;     Low-path dispatch table (file 0x9558 / `$C09558`) — 77 words, adopted as
;     data in action_script_tables.nim. Operand of `JSR ($abs,X)`.
;   ActionScriptHighDispatch = $95E2
;     High-path dispatch table (file 0x95E2 / `$C095E2`) — last 8 words of the
;     low table (opcodes `>= $70`).
;   EntitySlotDp = $8A
;     DP: current entity slot index (X base into per-entity abs,X arrays).
;   ScriptStreamDp = $80
;     Far script stream base for `LDA [$80],Y` (lo/hi at $80/$81, bank at $82).
;   ScriptStreamBankDp = $82
;   OpcodeScratchDp = $90
;     DP scratch: full opcode byte on the high path before nibble split.
;   EntityWorkBase = $15A2
;     Per-entity 8-byte work-row base; `entity*8 + $15A2` → DP $84.
;     TODO: name the $15A2 table once its fields are pinned live.
;   EntityWorkPtrDp = $84
;   EntityWaitCounter = $1372
;     Per-entity wait / frame counter. Nonzero at entry → skip fetch, DEC, RTS.
;     Handlers (e.g. op $06 WAIT) and high-path low-nibble also write it.
;   EntityScriptPc = $13FE
;     Per-entity script PC (Y index into `[$80]`).
;   EntityScriptBank = $148A
;     Per-entity script bank byte mirrored into DP $82 for the far load.
;   OpcodeHighThreshold = $70
;     Opcodes `>= $70` take the high path (nibble wait + 8-slot table).
;   OpcodeHighNibbleMask = $70
;   OpcodeWaitNibbleMask = $0F
;   ByteMask = $FF
;
.a16
.i16
LDX $8A  ; EntitySlotDp — DP: current entity slot index (X base into per-entity abs,X arrays).
LDA $1372,X  ; EntityWaitCounter — Per-entity wait / frame counter. Nonzero at entry → skip fetch, DEC, RTS.
BNE waitTick
LDY $13FE,X  ; EntityScriptPc — Per-entity script PC (Y index into `[$80]`).
LDA $148A,X  ; EntityScriptBank — Per-entity script bank byte mirrored into DP $82 for the far load.
STA $82  ; ScriptStreamBankDp
TXA
ASL A
ASL A
ASL A
ADC #$15A2  ; EntityWorkBase — Per-entity 8-byte work-row base; `entity*8 + $15A2` → DP $84.
STA $84  ; EntityWorkPtrDp
fetchOpcode:
LDA [$80],Y  ; ScriptStreamDp — Far script stream base for `LDA [$80],Y` (lo/hi at $80/$81, bank at $82).
INY
AND #$FF  ; ByteMask
CMP #$70  ; OpcodeHighThreshold — Opcodes `>= $70` take the high path (nibble wait + 8-slot table).
BCS highPath
ASL A
TAX
JSR ($9558,X)  ; ActionScriptLowDispatch — Low-path dispatch table (file 0x9558 / `$C09558`) — 77 words, adopted as
BRA afterDispatch
highPath:
STA $90  ; OpcodeScratchDp — DP scratch: full opcode byte on the high path before nibble split.
AND #$0F  ; OpcodeWaitNibbleMask
STA $1372,X  ; EntityWaitCounter — Per-entity wait / frame counter. Nonzero at entry → skip fetch, DEC, RTS.
LDA $90  ; OpcodeScratchDp — DP scratch: full opcode byte on the high path before nibble split.
AND #$70  ; OpcodeHighNibbleMask
LSR A
LSR A
LSR A
TAX
JSR ($95E2,X)  ; ActionScriptHighDispatch — High-path dispatch table (file 0x95E2 / `$C095E2`) — last 8 words of the
afterDispatch:
LDX $8A  ; EntitySlotDp — DP: current entity slot index (X base into per-entity abs,X arrays).
LDA $1372,X  ; EntityWaitCounter — Per-entity wait / frame counter. Nonzero at entry → skip fetch, DEC, RTS.
BEQ fetchOpcode
TYA
STA $13FE,X  ; EntityScriptPc — Per-entity script PC (Y index into `[$80]`).
LDA $82  ; ScriptStreamBankDp
STA $148A,X  ; EntityScriptBank — Per-entity script bank byte mirrored into DP $82 for the far load.
waitTick:
DEC $1372,X  ; EntityWaitCounter — Per-entity wait / frame counter. Nonzero at entry → skip fetch, DEC, RTS.
RTS
