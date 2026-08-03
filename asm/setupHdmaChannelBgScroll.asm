; setupHdmaChannelBgScroll
; Ported from snes_src/hdma_channel.nim :: setupHdmaChannelBgScroll (evidence-preserving re-port).
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
; --- setupHdmaChannelBgScroll ---
; Program one HDMA channel to feed a BG scroll register from WRAM.
;
; Entry (JSL): 16-bit A = DMA channel index (0..7); X = index into the BBAD
; table at `$C0AE1D` (which BGnHOFS/VOFS to target); Y selects the WRAM
; template (`Y==0` → copy `$C0AE26` → `$3C32`, else `$C0AE2D` → `$3C3C`)
; and becomes the branch flag after the stack dance below.
;
; Sequence:
; 1. Save BBAD from `BgScrollBbadTable,X`; `channel<<4` → X (DMA stride).
; 2. A1B/DASB ← `$7E`, BBAD ← table byte, DMAP ← `$42` (indirect mode 2).
; 3. Copy 8 template bytes into the chosen WRAM slot; A1T ← that address.
; 4. `$001F |= $C0AE16[channel]` (HDMAEN shadow bit).
;
; Evidence (registers / tables):
; - long `$4304,X` / `$4307,X` — A1B / DASB = `$7E` (WRAM).
; - long `$4301,X` — BBAD from `$0D/$0F/$11/$13/$0E/$10/$12/$14`
; (BG1-4 HOFS/VOFS).
; - long `$4300,X` — DMAP `$42`.
; - long `$4302,X` — A1T = `$3C32` or `$3C3C`.
; - abs `$001F` — HDMAEN shadow (NMI → `$420C`).
;
; Callers: JSL `$C0ADB2` from `$C2CF15` / `$C2CF25`. Sibling of
; `setupHdmaChannelWh0` (same enable-bit tail, different BBAD/DMAP/bank).
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
PHY
TAY
LDA $C0AE1D,X  ; BgScrollBbadTable — ROM BBAD table for BG scroll HDMA: `$0D,$0F,$11,$13,$0E,$10,$12,$14`
PHA
TYA
ASL A
ASL A
ASL A
ASL A
TAX
SEP #$20  ; StatusM
.a8
.i16
LDA #$7E  ; WramBank — A1B/DASB bank for BG-scroll tables living in WRAM.
STA $004304,X  ; DmaPA1b
STA $004307,X  ; DmaPDasb
PLA
STA $004301,X  ; DmaPBbad
PLA
LDA #$42  ; BgScrollDmap — DMAP `$42`: bit6=indirect HDMA, mode 2 = two registers write-once
STA $004300,X  ; DmaPDmap — Offsets within a channel block.
REP #$20  ; StatusM
.a16
.i16
PLA
PHX
BNE template1
LDX #$06  ; HdmaTemplateCopyX — Word count for the 8-byte template copy loop (`LDX #$0006` then DEX×2).
copy0:
LDA $C0AE26,X  ; BgScrollHdmaTemplate0 — ROM HDMA table templates copied into WRAM `$3C32` / `$3C3C` (8 bytes each).
STA $3C32,X  ; BgScrollHdmaWram0 — WRAM destinations for the two template copies (A1T points here after load).
DEX
DEX
BPL copy0
LDA #$3C32  ; BgScrollHdmaWram0 — WRAM destinations for the two template copies (A1T points here after load).
BRA haveA1t
template1:
LDX #$06  ; HdmaTemplateCopyX — Word count for the 8-byte template copy loop (`LDX #$0006` then DEX×2).
copy1:
LDA $C0AE2D,X  ; BgScrollHdmaTemplate1
STA $3C3C,X  ; BgScrollHdmaWram1
DEX
DEX
BPL copy1
LDA #$3C3C  ; BgScrollHdmaWram1
haveA1t:
PLX
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
