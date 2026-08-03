; pollJoypads
; Ported from snes_src/joypad.nim :: pollJoypads (evidence-preserving re-port).
;
; Joypad auto-read poll — HVBJOY wait + JOY1/JOY2 latch into DP shadows
; (file 0x008496 / SNES $C08496).
;
; Main joypad sample entry used from the NMI-side path (`JSR $8496` at
; `$C08783`). Waits for the hardware auto-joypad read to finish, then JSR
; the raw register latch and edge-processing helpers. ADOPTED into the
; region registry (adopted.nim); gold-gated by tests/test_regions.nim.
;
;
; --- pollJoypads ---
; Wait for auto-joypad ready, latch pads, then compute new/repeat edges.
;
; Entry (JSR): any M; forces 8-bit A for the HVBJOY poll, then 16-bit A/X
; for the per-pad loop. Returns with RTS (not RTL).
;
; Sequence:
; 1. `SEP #$20` / spin on `LDA $4212 / LSR / BCS` until auto-read busy
; clears (HVBJOY bit 0).
; 2. `JSR $841B` — raw JOY1/JOY2 → DP `$77`/`$79` (and demo override).
; 3. `JSR $8456` — optional demo recorder (not adopted).
; 4. For X in `{2,0}` (pad 2 then pad 1): mask raw with `#$FFF0`, compute
; new = raw & ~prev, update prev, and run the auto-repeat timer into
; the repeat DP slot (`$0014` initial delay, `$0003` period).
; 5. If `$7E:436C` is zero, OR pad-2 shadows into pad-1 shadows.
; 6. If any new press remains, `INC $0A34`.
;
; Evidence (registers / call graph):
; - abs `$4212` HVBJOY — busy wait (bit 0 via LSR/BCS).
; - JSR `$841B` reads abs `$4218` JOY1 and `$421A` JOY2 into DP.
; - Sole traced caller: `$C08783` (`JSR $8496`) on the NMI-side path that
; also polls HVBJOY before entering this routine's bank-local frame.
;
; Named constants (values inlined below; names preserved as comments):
;   PollJoypadsOffset = $8496
;   PollJoypadsSnes = $C08496
;   HvbjoyReg = $4212
;     CPU MMIO: HVBJOY — bit 0 = auto-joypad-read busy.
;   ReadJoypadRegsAbs = $841B
;     Absolute low-16 of the raw joypad latch helper at `$C0841B` (same bank;
;     JSR operand is 16-bit). Reads JOY1 (`$4218`) → DP `$77` and JOY2
;     (`$421A`) → DP `$79` (with an optional demo-playback override).
;   RecordJoypadDemoAbs = $8456
;     Absolute low-16 of the demo-record helper at `$C08456` (same bank).
;     Not adopted here — only the call site is fixed.
;   JoyRawDp = $77
;     DP: raw joypad words after the latch helper (pad 1 at `$77`, pad 2 at `$79`).
;     Indexed as `$77,X` with X in `{0,2}`.
;   JoyPrevDp = $65
;     DP: previous-frame held buttons (same X stride).
;   JoyNewDp = $6D
;     DP: newly pressed buttons this frame (`raw & ~prev`).
;   JoyRepeatDp = $69
;     DP: auto-repeat / held-with-delay output.
;   JoyRepeatTimerDp = $71
;     DP: repeat countdown timer per pad.
;   JoyMaskedDp = $75
;     DP: masked raw (face/d-pad bits only after `AND #$FFF0`).
;   JoyPrev2Dp = $67
;     DP: pad-2 siblings of prev/new/repeat (X=0 uses `$65/$6D/$69`; the ORA
;     merge path also folds `$67/$6B/$6F` when `$7E436C` is clear).
;   JoyRepeat2Dp = $6B
;   JoyNew2Dp = $6F
;   JoyRepeatDelayInitial = $14
;     Initial auto-repeat delay (frames) after a new press.
;   JoyRepeatPeriod = $03
;     Repeat period once the initial delay expires.
;   JoyButtonMask = $FFF0
;     Mask keeping d-pad + face buttons (clears the low nibble signature bits).
;   JoyMergeGateWram = $7E436C
;     WRAM gate: when nonzero, skip the pad1|pad2 merge into the primary shadows.
;   JoyNewPressCounter = $0A34
;     Frame counter bumped when any newly-pressed button is nonzero.
;     TODO: pin all readers of `$0A34` before a stronger name in memory-map.md.
;   StatusM = $20
;   StatusMX = $30
;
.a16
.i16
SEP #$20  ; StatusM
.a8
.i16
waitAutoJoy:
LDA $4212  ; HvbjoyReg — CPU MMIO: HVBJOY — bit 0 = auto-joypad-read busy.
LSR A
BCS waitAutoJoy
JSR $841B  ; ReadJoypadRegsAbs — Absolute low-16 of the raw joypad latch helper at `$C0841B` (same bank;
JSR $8456  ; RecordJoypadDemoAbs — Absolute low-16 of the demo-record helper at `$C08456` (same bank).
REP #$30  ; StatusMX
.a16
.i16
LDX #$02
padLoop:
LDA $77,X  ; JoyRawDp — DP: raw joypad words after the latch helper (pad 1 at `$77`, pad 2 at `$79`).
AND #$FFF0  ; JoyButtonMask — Mask keeping d-pad + face buttons (clears the low nibble signature bits).
STA $75  ; JoyMaskedDp — DP: masked raw (face/d-pad bits only after `AND #$FFF0`).
LDA $65,X  ; JoyPrevDp — DP: previous-frame held buttons (same X stride).
EOR #$FFFF
AND $75  ; JoyMaskedDp — DP: masked raw (face/d-pad bits only after `AND #$FFF0`).
STA $6D,X  ; JoyNewDp — DP: newly pressed buttons this frame (`raw & ~prev`).
LDA $75  ; JoyMaskedDp — DP: masked raw (face/d-pad bits only after `AND #$FFF0`).
CMP $65,X  ; JoyPrevDp — DP: previous-frame held buttons (same X stride).
STA $65,X  ; JoyPrevDp — DP: previous-frame held buttons (same X stride).
BEQ sameButtons
LDA $6D,X  ; JoyNewDp — DP: newly pressed buttons this frame (`raw & ~prev`).
STA $69,X  ; JoyRepeatDp — DP: auto-repeat / held-with-delay output.
LDA #$14  ; JoyRepeatDelayInitial — Initial auto-repeat delay (frames) after a new press.
STA $71,X  ; JoyRepeatTimerDp — DP: repeat countdown timer per pad.
BRA nextPad
sameButtons:
LDY $71,X  ; JoyRepeatTimerDp — DP: repeat countdown timer per pad.
BEQ repeatFire
DEC $71,X  ; JoyRepeatTimerDp — DP: repeat countdown timer per pad.
STZ $69,X  ; JoyRepeatDp — DP: auto-repeat / held-with-delay output.
BRA nextPad
repeatFire:
STA $69,X  ; JoyRepeatDp — DP: auto-repeat / held-with-delay output.
LDA #$03  ; JoyRepeatPeriod — Repeat period once the initial delay expires.
STA $71,X  ; JoyRepeatTimerDp — DP: repeat countdown timer per pad.
nextPad:
DEX
DEX
BPL padLoop
LDA $7E436C  ; JoyMergeGateWram — WRAM gate: when nonzero, skip the pad1|pad2 merge into the primary shadows.
BNE skipMerge
LDA $67  ; JoyPrev2Dp — DP: pad-2 siblings of prev/new/repeat (X=0 uses `$65/$6D/$69`; the ORA
ORA $65  ; JoyPrevDp — DP: previous-frame held buttons (same X stride).
STA $65  ; JoyPrevDp — DP: previous-frame held buttons (same X stride).
LDA $6B  ; JoyRepeat2Dp
ORA $69  ; JoyRepeatDp — DP: auto-repeat / held-with-delay output.
STA $69  ; JoyRepeatDp — DP: auto-repeat / held-with-delay output.
LDA $6F  ; JoyNew2Dp
ORA $6D  ; JoyNewDp — DP: newly pressed buttons this frame (`raw & ~prev`).
STA $6D  ; JoyNewDp — DP: newly pressed buttons this frame (`raw & ~prev`).
skipMerge:
LDA $6D  ; JoyNewDp — DP: newly pressed buttons this frame (`raw & ~prev`).
BEQ done
INC $0A34  ; JoyNewPressCounter — Frame counter bumped when any newly-pressed button is nonzero.
done:
RTS
