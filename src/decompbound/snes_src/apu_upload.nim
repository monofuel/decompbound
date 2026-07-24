## APU package upload — SPC700 IPL handshake + block streamer
## (file 0x00AB06 / SNES $C0AB06).
##
## Documented in docs/audio.md Findings and matched by the HLE capture path in
## snesbus.nim ($2140-$2143). ADOPTED into the region registry (adopted.nim):
## convert_all carves these 183 bytes out of the enclosing traced region
## (0x00AB06-0x00AC2B), so this curated source produces $C0AB06..$C0ABBC.
## Gold-gated by tests/test_regions.nim.

import
  ../snes_asm

const
  ApuUploadOffset* = 0x00AB06
  ApuUploadSnes* = 0xC0AB06'u32
  ## 24-bit far pointer to the package stream: lo word at $00C6, bank byte at
  ## $00C8. Caller passes A = address, X = bank (REP #$30 on entry).
  PackagePtrLo* = 0x00C6'u32
  PackagePtrBank* = 0x00C8'u32
  ## APU communication ports (S-CPU side). Protocol: target addr → $2142/$2143,
  ## command/flag → $2141, counter+data pairs → $2140 (16-bit STA writes both
  ## $2140 counter and $2141 payload when M is clear).
  ApuPort0* = 0x2140'u32
  ApuPort1* = 0x2141'u32
  ApuPort2* = 0x2142'u32
  ## NMITIMEN shadow in WRAM; bit 7 = NMI enable. Cleared for the transfer,
  ## restored after, and mirrored to the hardware register.
  NmiEnableShadow* = 0x001E'u32
  NmiEnableMask* = 0x80'u32
  NmiTimenAddr* = 0x004200'u32
  ## SPC700 IPL ready signature read from $2140/$2141 as a 16-bit word.
  IplReadySignature* = 0xBBAA'u32
  ## First transfer kick-off counter written to $2140 (IPL start-transfer).
  # TODO: full IPL command set; 0xCC is the documented begin-transfer byte.
  IplBeginTransfer* = 0xCC'u32
  ## $FF written to $2140 forces a running driver back to the IPL (reboot
  ## between tracks). Same magic the snesbus HLE treats as ahsRunning → ahsIdle.
  # TODO: confirm all IPL reboot paths; this matches the observed warm reboot.
  IplRebootCommand* = 0x00FF'u32
  ## Default entry address when a package ends with len == 0 (kick SPC at $0500).
  DefaultApuEntry* = 0x0500'u32
  ## Zero data-bank / direct-page for long-pointer reads of the package stream.
  ZeroBankOrDp* = 0x0000'u32
  StatusM* = 0x20'u32
  StatusMX* = 0x30'u32

proc uploadApuPackages*(): seq[uint8] =
  ## Stream music/driver packages into APU RAM via the SPC700 IPL protocol.
  ##
  ## Entry (JSL): native mode, 16-bit A/X. A = package stream address, X = bank
  ## (stored as a 24-bit far pointer at $C6/$C8). Sets DBR and D to 0 so
  ## `LDA [$C6],Y` walks the caller's stream.
  ##
  ## Handshake: wait for IPL ready ($BBAA on $2140), or JSR the local reboot
  ## helper that writes $FF until $BBAA reappears. Disables NMI for the transfer
  ## (clears bit 7 of $001E / $4200), then for each block reads
  ## `[u16 len][u16 apuAddr]` from the stream (len == 0 → entry $0500 and no
  ## payload), writes addr to $2142, a flag derived from (len == 1) to $2141,
  ## and streams payload bytes as 16-bit counter+data stores to $2140.
  ##
  ## Wait loop at $C0AB90 polls $2140 until 0 after the final block, restores
  ## NMI enable, PLD/PLB, RTL. The IPL reboot helper at $C0ABA8 is only reached
  ## via the internal JSR (no external callers).
  ##
  ## Call sites: song loader $C4FBBD path (JSL $C0AB06 at $C4FBB1 and siblings).
  snesAsm(ApuUploadSnes, NativeFlags16):
    rep StatusMX
    sta abs PackagePtrLo
    stx abs PackagePtrBank
    phb
    pea abs ZeroBankOrDp
    plb
    plb
    phd
    pea abs ZeroBankOrDp
    pld
    ldy 0x0
    lda abs ApuPort0
    cmp IplReadySignature
    beq "iplReady"
    jsr "rebootToIpl"
    label "iplReady"
    sep StatusM
    lda abs NmiEnableShadow
    andOp 0x7F
    sta abs NmiEnableShadow
    sta long NmiTimenAddr
    lda IplBeginTransfer
    bra "beginBlock"
    label "readPayloadByte"
    lda dpily PackagePtrLo
    iny
    xba
    lda 0x0
    bra "sendWord"
    label "nextPayloadByte"
    xba
    lda dpily PackagePtrLo
    iny
    xba
    label "waitPort0Match"
    cmp abs ApuPort0
    bne "waitPort0Match"
    inc a
    label "sendWord"
    rep StatusM
    sta abs ApuPort0
    sep StatusM
    dex
    bne "nextPayloadByte"
    label "waitPort0AfterBlock"
    cmp abs ApuPort0
    bne "waitPort0AfterBlock"
    label "avoidZeroCounter"
    adc 0x3
    beq "avoidZeroCounter"
    label "beginBlock"
    pha
    rep StatusM
    lda dpily PackagePtrLo
    bne "nonEmptyBlock"
    tax
    lda DefaultApuEntry
    bra "writeBlockAddr"
    label "nonEmptyBlock"
    tax
    iny
    iny
    lda dpily PackagePtrLo
    iny
    iny
    label "writeBlockAddr"
    sta abs ApuPort2
    sep StatusM
    cpx 0x1
    lda 0x0
    rol a
    sta abs ApuPort1
    adc 0x7F
    pla
    sta abs ApuPort0
    label "waitHeaderAck"
    cmp abs ApuPort0
    bne "waitHeaderAck"
    bvs "readPayloadByte"
    rep StatusM
    label "waitTransferIdle"
    lda abs ApuPort0
    bne "waitTransferIdle"
    sep StatusM
    lda abs NmiEnableShadow
    ora NmiEnableMask
    sta abs NmiEnableShadow
    sta long NmiTimenAddr
    rep StatusM
    pld
    plb
    rtl
    label "rebootToIpl"
    stz abs ApuPort2
    stz abs ApuPort0
    label "waitIplReady"
    lda IplRebootCommand
    sta abs ApuPort0
    lda abs ApuPort0
    cmp IplReadySignature
    bne "waitIplReady"
    rts
