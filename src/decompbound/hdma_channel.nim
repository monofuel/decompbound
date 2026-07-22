## HDMA channel helpers — enable shadow + WH0-targeted channel setup
## (file 0x00AE34 / SNES $C0AE34 and $C0B0B8).
##
## Small JSL-callable writers that clear one bit of the HDMA-enable WRAM
## shadow, or program a DMA channel to feed WH0 (`$2126`) via HDMA and set
## that channel's enable bit. ADOPTED into the region registry (adopted.nim);
## gold-gated by tests/test_regions.nim.

import
  ./snes_asm

const
  ClearHdmaEnableBitOffset* = 0x00AE34
  ClearHdmaEnableBitSnes* = 0xC0AE34'u32
  SetupHdmaChannelWh0Offset* = 0x00B0B8
  SetupHdmaChannelWh0Snes* = 0xC0B0B8'u32
  ## WRAM shadow of HDMAEN (`$420C`). NMI flushes `$001F` → `$420C` when
  ## brightness is not forced-blank (see `$C08346` `LDX $1F / STX $420C`).
  HdmaEnableShadow* = 0x001F'u32
  ## ROM table of per-channel clear masks: `~$01,~$02,...,~$80` at `$C0AE44`.
  ## Data, not adopted — only referenced by address.
  HdmaClearMaskTable* = 0xC0AE44'u32
  ## ROM table of per-channel set bits: `$01,$02,...,$80` at `$C0AE16`.
  HdmaSetBitTable* = 0xC0AE16'u32
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
