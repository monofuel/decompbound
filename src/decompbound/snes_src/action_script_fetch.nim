## Entity action-script VM fetch / dispatch loop
## (file 0x009506 / SNES $C09506, 82 bytes through RTS at $C09557).
##
## One entity tick for the `[$80],Y` action-script interpreter documented in
## docs/scripts.md. Called via JSR from the entity walker at `$C094E9`. When
## the per-entity wait counter at `$1372,X` is nonzero the tick only DECs it;
## otherwise the loop loads the script PC/bank, fetches opcodes until a wait
## is scheduled, and dispatches through the low (`$C09558`) or high
## (`$C095E2`) jump table already adopted as data in action_script_tables.nim.
##
## ADOPTED into the region registry (adopted.nim); convert_all carves these
## 82 bytes out of the former enclosing span 0x009250-0x009557. Gold-gated by
## tests/test_regions.nim and tests/test_action_script_fetch.nim.

import
  ../snes_asm

const
  ActionScriptFetchOffset* = 0x009506
  ActionScriptFetchSnes* = 0xC09506'u32
  ActionScriptFetchLen* = 0x52
  ## Low-path dispatch table (file 0x9558 / `$C09558`) — 77 words, adopted as
  ## data in action_script_tables.nim. Operand of `JSR ($abs,X)`.
  ActionScriptLowDispatch* = 0x9558'u32
  ## High-path dispatch table (file 0x95E2 / `$C095E2`) — last 8 words of the
  ## low table (opcodes `>= $70`).
  ActionScriptHighDispatch* = 0x95E2'u32
  ## DP: current entity slot index (X base into per-entity abs,X arrays).
  EntitySlotDp* = 0x8A'u32
  ## Far script stream base for `LDA [$80],Y` (lo/hi at $80/$81, bank at $82).
  ScriptStreamDp* = 0x80'u32
  ScriptStreamBankDp* = 0x82'u32
  ## DP scratch: full opcode byte on the high path before nibble split.
  OpcodeScratchDp* = 0x90'u32
  ## Per-entity 8-byte work-row base; `entity*8 + $15A2` → DP $84.
  ## TODO: name the $15A2 table once its fields are pinned live.
  EntityWorkBase* = 0x15A2'u32
  EntityWorkPtrDp* = 0x84'u32
  ## Per-entity wait / frame counter. Nonzero at entry → skip fetch, DEC, RTS.
  ## Handlers (e.g. op $06 WAIT) and high-path low-nibble also write it.
  EntityWaitCounter* = 0x1372'u32
  ## Per-entity script PC (Y index into `[$80]`).
  EntityScriptPc* = 0x13FE'u32
  ## Per-entity script bank byte mirrored into DP $82 for the far load.
  EntityScriptBank* = 0x148A'u32
  ## Opcodes `>= $70` take the high path (nibble wait + 8-slot table).
  OpcodeHighThreshold* = 0x0070'u32
  OpcodeHighNibbleMask* = 0x0070'u32
  OpcodeWaitNibbleMask* = 0x000F'u32
  ByteMask* = 0x00FF'u32

proc actionScriptFetch*(): seq[uint8] =
  ## Run one entity action-script tick: wait countdown or fetch/dispatch.
  ##
  ## Entry (JSR): DP `$8A` = entity slot. M is 16-bit (immediates are word-
  ## sized). Clobbers A/X/Y and the DP scratch used below.
  ##
  ## Control flow:
  ## 1. **Wait tick** — if `$1372,X` ≠ 0, DEC it and RTS (no stream advance).
  ## 2. **Setup** — load script PC from `$13FE,X` into Y, bank from `$148A,X`
  ##    into DP `$82`, and `entity*8 + $15A2` into DP `$84`.
  ## 3. **Fetch loop** — `LDA [$80],Y / INY / AND #$00FF`. Opcode byte is
  ##    consumed before the handler runs; handlers see only operands at Y.
  ## 4. **Low path** (`opcode < $70`) — `ASL / TAX / JSR ($9558,X)`.
  ## 5. **High path** (`opcode >= $70`) — low nibble → `$1372,X` (inline wait),
  ##    high nibble `AND #$70 / LSR×3 / TAX / JSR ($95E2,X)`.
  ## 6. After dispatch, if `$1372,X` is still 0, fetch the next opcode;
  ##    otherwise save Y/`$82` back to `$13FE,X` / `$148A,X`, DEC wait, RTS.
  ##
  ## Evidence: gold disasm `code_bank00` `$C09506..$C09557`; dispatch tables
  ## gold-gated in action_script_tables.nim; operand widths for ops $06/$19/$42
  ## in docs/scripts.md.
  snesAsm(ActionScriptFetchSnes, NativeFlags16):
    ldx dp EntitySlotDp
    lda absx EntityWaitCounter
    bne "waitTick"
    ldy absx EntityScriptPc
    lda absx EntityScriptBank
    sta dp ScriptStreamBankDp
    txa
    asl a
    asl a
    asl a
    adc EntityWorkBase
    sta dp EntityWorkPtrDp
    label "fetchOpcode"
    lda dpily ScriptStreamDp
    iny
    andOp ByteMask
    cmp OpcodeHighThreshold
    bcs "highPath"
    asl a
    tax
    jsr absindx ActionScriptLowDispatch
    bra "afterDispatch"
    label "highPath"
    sta dp OpcodeScratchDp
    andOp OpcodeWaitNibbleMask
    sta absx EntityWaitCounter
    lda dp OpcodeScratchDp
    andOp OpcodeHighNibbleMask
    lsr a
    lsr a
    lsr a
    tax
    jsr absindx ActionScriptHighDispatch
    label "afterDispatch"
    ldx dp EntitySlotDp
    lda absx EntityWaitCounter
    beq "fetchOpcode"
    tya
    sta absx EntityScriptPc
    lda dp ScriptStreamBankDp
    sta absx EntityScriptBank
    label "waitTick"
    dec absx EntityWaitCounter
    rts
