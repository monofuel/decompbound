; setupHdmaChannelWh0
; Ported from snes_src/hdma_channel.nim :: setupHdmaChannelWh0 (evidence-preserving re-port).
;
; HDMA channel helpers — enable shadow, WH0 setup, BG-scroll setup
; (file 0x00AE34 / SNES $C0AE34, $C0B0B8, and $C0ADB2).
;
; Small JSL-callable writers that clear one bit of the HDMA-enable WRAM
; shadow, or program a DMA channel for WH0 / BG scroll HDMA and set that
; channel's enable bit. ADOPTED into the region registry (adopted.nim);
; gold-gated by tests/test_regions.nim.
;
;
; --- setupHdmaChannelWh0 ---
; Program one HDMA channel to feed WH0 (`$2126`) and enable it in `$001F`.
;
; Entry (JSL): 16-bit A = DMA channel index (0..7). X is unused as channel
; (overwritten). Direct page `$0E` is a long pointer to the HDMA table whose
; first byte is DMAP; `$10` is the table bank written to A1B and DASB.
;
; Sequence:
; 1. `channel << 4` → X (channel register stride).
; 2. A1B/DASB ← `$10`, BBAD ← `$26` (WH0), DMAP ← `[$0E]`.
; 3. A1T ← `$0E + 1` (table body after the DMAP byte).
; 4. `$001F |= $C0AE16[channel]` (set HDMAEN shadow bit).
;
; Evidence (registers written):
; - long `$4304,X` / `$4307,X` — A1B / DASB bank bytes.
; - long `$4301,X` — BBAD = `$26` → WH0.
; - long `$4300,X` — DMAP from table.
; - long `$4302,X` — A1T table address.
; - abs `$001F` — HDMAEN shadow (NMI → `$420C`).
;
; Callers: JSL `$C0B0B8` from `$C4AABD` / `$C4AAFC` (window HDMA setup).
;
; Named constants (values inlined below; names preserved as comments):
;   ClearHdmaEnableBitOffset = $AE34
;   ClearHdmaEnableBitSnes = $C0AE34
;   SetupHdmaChannelWh0Offset = $B0B8
;   SetupHdmaChannelWh0Snes = $C0B0B8
;   SetupHdmaChannelBgScrollOffset = $ADB2
;   SetupHdmaChannelBgScrollSnes = $C0ADB2
;   HdmaEnableShadow = $1F
;     WRAM shadow of HDMAEN (`$420C`). NMI flushes `$001F` → `$420C` when
;     brightness is not forced-blank (see `$C08346` `LDX $1F / STX $420C`).
;   HdmaClearMaskTable = $C0AE44
;     ROM table of per-channel clear masks: `~$01,~$02,...,~$80` at `$C0AE44`.
;     Data, not adopted — only referenced by address.
;   HdmaSetBitTable = $C0AE16
;     ROM table of per-channel set bits: `$01,$02,...,$80` at `$C0AE16`.
;   BgScrollBbadTable = $C0AE1D
;     ROM BBAD table for BG scroll HDMA: `$0D,$0F,$11,$13,$0E,$10,$12,$14`
;     → BGnHOFS / BGnVOFS (`$210D`..`$2114`). Indexed by entry X.
;   BgScrollHdmaTemplate0 = $C0AE26
;     ROM HDMA table templates copied into WRAM `$3C32` / `$3C3C` (8 bytes each).
;     Data, not adopted — only referenced by address.
;   BgScrollHdmaTemplate1 = $C0AE2D
;   BgScrollHdmaWram0 = $3C32
;     WRAM destinations for the two template copies (A1T points here after load).
;   BgScrollHdmaWram1 = $3C3C
;   DmaPBase = $4300
;     DMA channel base: `$4300 + channel*16`. Index = A<<4 on entry.
;   DmaPDmap = $4300
;     Offsets within a channel block.
;   DmaPBbad = $4301
;   DmaPA1t = $4302
;   DmaPA1b = $4304
;   DmaPDasb = $4307
;   Wh0Bbad = $26
;     BBAD value `$26` → PPU WH0 (`$2126`), window 1 left edge (HDMA can
;     also cover WH1 at `$2127` depending on DMAP).
;   BgScrollDmap = $42
;     DMAP `$42`: bit6=indirect HDMA, mode 2 = two registers write-once
;     (correct for write-twice scroll regs fed as a word pair).
;   WramBank = $7E
;     A1B/DASB bank for BG-scroll tables living in WRAM.
;   HdmaTemplateCopyX = $06
;     Word count for the 8-byte template copy loop (`LDX #$0006` then DEX×2).
;   HdmaTableBankDp = $10
;     Direct-page: HDMA table bank byte reused for A1B/DASB.
;   HdmaTablePtrDp = $0E
;     Direct-page: long pointer to the caller's HDMA table (byte 0 = DMAP).
;   StatusM = $20
;
.a16
.i16
TAY
ASL A
ASL A
ASL A
ASL A
TAX
SEP #$20  ; StatusM
.a8
.i16
LDA $10  ; HdmaTableBankDp — Direct-page: HDMA table bank byte reused for A1B/DASB.
STA $004304,X  ; DmaPA1b
STA $004307,X  ; DmaPDasb
LDA #$26  ; Wh0Bbad — BBAD value `$26` → PPU WH0 (`$2126`), window 1 left edge (HDMA can
STA $004301,X  ; DmaPBbad
LDA [$0E]  ; HdmaTablePtrDp — Direct-page: long pointer to the caller's HDMA table (byte 0 = DMAP).
STA $004300,X  ; DmaPDmap — Offsets within a channel block.
REP #$20  ; StatusM
.a16
.i16
LDA $0E  ; HdmaTablePtrDp — Direct-page: long pointer to the caller's HDMA table (byte 0 = DMAP).
INC A
STA $004302,X  ; DmaPA1t
SEP #$20  ; StatusM
.a8
.i16
TYX
LDA $001F  ; HdmaEnableShadow — WRAM shadow of HDMAEN (`$420C`). NMI flushes `$001F` → `$420C` when
ORA $C0AE16,X  ; HdmaSetBitTable — ROM table of per-channel set bits: `$01,$02,...,$80` at `$C0AE16`.
STA $001F  ; HdmaEnableShadow — WRAM shadow of HDMAEN (`$420C`). NMI flushes `$001F` → `$420C` when
REP #$20  ; StatusM
.a16
.i16
RTL

