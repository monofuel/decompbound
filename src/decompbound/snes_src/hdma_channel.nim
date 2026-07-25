## HDMA channel helpers — enable shadow, WH0 setup, BG-scroll setup
## (file 0x00AE34 / SNES $C0AE34, $C0B0B8, and $C0ADB2).
##
## Small JSL-callable writers that clear one bit of the HDMA-enable WRAM
## shadow, or program a DMA channel for WH0 / BG scroll HDMA and set that
## channel's enable bit. ADOPTED into the region registry (adopted.nim);
## gold-gated by tests/test_regions.nim.

import
  ../snes_asm

const
  ClearHdmaEnableBitOffset* = 0x00AE34
  ClearHdmaEnableBitSnes* = 0xC0AE34'u32
  SetupHdmaChannelWh0Offset* = 0x00B0B8
  SetupHdmaChannelWh0Snes* = 0xC0B0B8'u32
  SetupHdmaChannelBgScrollOffset* = 0x00ADB2
  SetupHdmaChannelBgScrollSnes* = 0xC0ADB2'u32
  ## WRAM shadow of HDMAEN (`$420C`). NMI flushes `$001F` → `$420C` when
  ## brightness is not forced-blank (see `$C08346` `LDX $1F / STX $420C`).
  HdmaEnableShadow* = 0x001F'u32
  ## ROM table of per-channel clear masks: `~$01,~$02,...,~$80` at `$C0AE44`.
  ## Data, not adopted — only referenced by address.
  HdmaClearMaskTable* = 0xC0AE44'u32
  ## ROM table of per-channel set bits: `$01,$02,...,$80` at `$C0AE16`.
  HdmaSetBitTable* = 0xC0AE16'u32
  ## ROM BBAD table for BG scroll HDMA: `$0D,$0F,$11,$13,$0E,$10,$12,$14`
  ## → BGnHOFS / BGnVOFS (`$210D`..`$2114`). Indexed by entry X.
  BgScrollBbadTable* = 0xC0AE1D'u32
  ## ROM HDMA table templates copied into WRAM `$3C32` / `$3C3C` (8 bytes each).
  ## Data, not adopted — only referenced by address.
  BgScrollHdmaTemplate0* = 0xC0AE26'u32
  BgScrollHdmaTemplate1* = 0xC0AE2D'u32
  ## WRAM destinations for the two template copies (A1T points here after load).
  BgScrollHdmaWram0* = 0x3C32'u32
  BgScrollHdmaWram1* = 0x3C3C'u32
  ## DMA channel base: `$4300 + channel*16`. Index = A<<4 on entry.
  DmaPBase* = 0x004300'u32
  ## Offsets within a channel block.
  DmaPDmap* = 0x004300'u32   ## DMAP — transfer pattern / HDMA mode
  DmaPBbad* = 0x004301'u32   ## BBAD — B-bus address (PPU reg low byte)
  DmaPA1t* = 0x004302'u32    ## A1T — HDMA table address (16-bit)
  DmaPA1b* = 0x004304'u32    ## A1B — HDMA table bank
  DmaPDasb* = 0x004307'u32   ## DASB — indirect HDMA bank
  ## BBAD value `$26` → PPU WH0 (`$2126`), window 1 left edge (HDMA can
  ## also cover WH1 at `$2127` depending on DMAP).
  Wh0Bbad* = 0x26'u32
  ## DMAP `$42`: bit6=indirect HDMA, mode 2 = two registers write-once
  ## (correct for write-twice scroll regs fed as a word pair).
  BgScrollDmap* = 0x42'u32
  ## A1B/DASB bank for BG-scroll tables living in WRAM.
  WramBank* = 0x7E'u32
  ## Word count for the 8-byte template copy loop (`LDX #$0006` then DEX×2).
  HdmaTemplateCopyX* = 0x0006'u32
  ## Direct-page: HDMA table bank byte reused for A1B/DASB.
  HdmaTableBankDp* = 0x10'u32
  ## Direct-page: long pointer to the caller's HDMA table (byte 0 = DMAP).
  HdmaTablePtrDp* = 0x0E'u32
  StatusM* = 0x20'u32

proc clearHdmaEnableBit*(): seq[uint8] =
  ## Clear one channel bit in the HDMAEN shadow at `$001F`.
  ##
  ## Entry (JSL): 16-bit A holds the channel index (0..7); `TAX` then 8-bit A
  ## loads `$001F`, `AND longx $C0AE44` (mask table `FE FD FB F7 EF DF BF 7F`),
  ## stores the result back, restores 16-bit A, RTL.
  ##
  ## Register written: WRAM `$001F` — the HDMAEN shadow that NMI copies to
  ## hardware `$420C`. Does not poke `$420C` itself (safe outside vblank).
  ## Counterpart of the ORA-into-`$001F` tail on `setupHdmaChannelWh0`.
  ##
  ## Callers: JSL `$C0AE34` from banks `$C2` / `$C4` (window teardown paths
  ## that also call `configurePpuWindows`).
  snesAsm(ClearHdmaEnableBitSnes, NativeFlags16):
    tax
    sep StatusM
    lda abs HdmaEnableShadow
    andOp longx HdmaClearMaskTable
    sta abs HdmaEnableShadow
    rep StatusM
    rtl

proc setupHdmaChannelWh0*(): seq[uint8] =
  ## Program one HDMA channel to feed WH0 (`$2126`) and enable it in `$001F`.
  ##
  ## Entry (JSL): 16-bit A = DMA channel index (0..7). X is unused as channel
  ## (overwritten). Direct page `$0E` is a long pointer to the HDMA table whose
  ## first byte is DMAP; `$10` is the table bank written to A1B and DASB.
  ##
  ## Sequence:
  ## 1. `channel << 4` → X (channel register stride).
  ## 2. A1B/DASB ← `$10`, BBAD ← `$26` (WH0), DMAP ← `[$0E]`.
  ## 3. A1T ← `$0E + 1` (table body after the DMAP byte).
  ## 4. `$001F |= $C0AE16[channel]` (set HDMAEN shadow bit).
  ##
  ## Evidence (registers written):
  ## - long `$4304,X` / `$4307,X` — A1B / DASB bank bytes.
  ## - long `$4301,X` — BBAD = `$26` → WH0.
  ## - long `$4300,X` — DMAP from table.
  ## - long `$4302,X` — A1T table address.
  ## - abs `$001F` — HDMAEN shadow (NMI → `$420C`).
  ##
  ## Callers: JSL `$C0B0B8` from `$C4AABD` / `$C4AAFC` (window HDMA setup).
  snesAsm(SetupHdmaChannelWh0Snes, NativeFlags16):
    tay
    asl a
    asl a
    asl a
    asl a
    tax
    sep StatusM
    lda dp HdmaTableBankDp
    sta longx DmaPA1b
    sta longx DmaPDasb
    lda Wh0Bbad
    sta longx DmaPBbad
    lda dpil HdmaTablePtrDp
    sta longx DmaPDmap
    rep StatusM
    lda dp HdmaTablePtrDp
    inc a
    sta longx DmaPA1t
    sep StatusM
    tyx
    lda abs HdmaEnableShadow
    ora longx HdmaSetBitTable
    sta abs HdmaEnableShadow
    rep StatusM
    rtl

proc setupHdmaChannelBgScroll*(): seq[uint8] =
  ## Program one HDMA channel to feed a BG scroll register from WRAM.
  ##
  ## Entry (JSL): 16-bit A = DMA channel index (0..7); X = index into the BBAD
  ## table at `$C0AE1D` (which BGnHOFS/VOFS to target); Y selects the WRAM
  ## template (`Y==0` → copy `$C0AE26` → `$3C32`, else `$C0AE2D` → `$3C3C`)
  ## and becomes the branch flag after the stack dance below.
  ##
  ## Sequence:
  ## 1. Save BBAD from `BgScrollBbadTable,X`; `channel<<4` → X (DMA stride).
  ## 2. A1B/DASB ← `$7E`, BBAD ← table byte, DMAP ← `$42` (indirect mode 2).
  ## 3. Copy 8 template bytes into the chosen WRAM slot; A1T ← that address.
  ## 4. `$001F |= $C0AE16[channel]` (HDMAEN shadow bit).
  ##
  ## Evidence (registers / tables):
  ## - long `$4304,X` / `$4307,X` — A1B / DASB = `$7E` (WRAM).
  ## - long `$4301,X` — BBAD from `$0D/$0F/$11/$13/$0E/$10/$12/$14`
  ##   (BG1-4 HOFS/VOFS).
  ## - long `$4300,X` — DMAP `$42`.
  ## - long `$4302,X` — A1T = `$3C32` or `$3C3C`.
  ## - abs `$001F` — HDMAEN shadow (NMI → `$420C`).
  ##
  ## Callers: JSL `$C0ADB2` from `$C2CF15` / `$C2CF25`. Sibling of
  ## `setupHdmaChannelWh0` (same enable-bit tail, different BBAD/DMAP/bank).
  snesAsm(SetupHdmaChannelBgScrollSnes, NativeFlags16):
    phy
    tay
    lda longx BgScrollBbadTable
    pha
    tya
    asl a
    asl a
    asl a
    asl a
    tax
    sep StatusM
    lda WramBank
    sta longx DmaPA1b
    sta longx DmaPDasb
    pla
    sta longx DmaPBbad
    pla
    lda BgScrollDmap
    sta longx DmaPDmap
    rep StatusM
    pla
    phx
    bne "template1"
    ldx HdmaTemplateCopyX
    label "copy0"
    lda longx BgScrollHdmaTemplate0
    sta absx BgScrollHdmaWram0
    dex
    dex
    bpl "copy0"
    lda BgScrollHdmaWram0
    bra "haveA1t"
    label "template1"
    ldx HdmaTemplateCopyX
    label "copy1"
    lda longx BgScrollHdmaTemplate1
    sta absx BgScrollHdmaWram1
    dex
    dex
    bpl "copy1"
    lda BgScrollHdmaWram1
    label "haveA1t"
    plx
    sta longx DmaPA1t
    sep StatusM
    tyx
    lda abs HdmaEnableShadow
    ora longx HdmaSetBitTable
    sta abs HdmaEnableShadow
    rep StatusM
    rtl
