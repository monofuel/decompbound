## Song loader / selector — song ID → pack indices → APU package upload
## (file 0x04FBBD / SNES $C4FBBD).
##
## docs/audio.md Findings: called with a song ID; walks the song table
## (file 0x04F70A, 3 bytes/song, index (id-1)*3) and pack table
## (file 0x04F947, 3 bytes/pack = [bank, addrL, addrH]), then JSL $C0AB06
## (uploadApuPackages) for each pack that changed. Tail pokes the play
## command via writeApuPort0 ($C0ABBD). ADOPTED mid-region after the small
## RTS helper at $C4FB42 (still generated); gold-gated by tests/test_regions.nim.

import
  ../snes_asm

const
  LoadSongOffset* = 0x04FBBD
  LoadSongSnes* = 0xC4FBBD'u32
  ## Song table: 3 pack indices per song, indexed (songId - 1) * 3.
  SongTableBase* = 0xC4F70A'u32
  ## Pack table far pointer built in DP $06/$08: bank $C4, addr $F947.
  PackTableAddr* = 0xF947'u32
  PackTableBank* = 0x00C4'u32
  ## Same-bank RTS helper at $C4FB42: sets $B547 = $FFFF (APU addr mask) and
  ## returns A (pack bank). Callers TAX the bank then JSL uploadApuPackages.
  PrepPackBankHelper* = 0xFB42'u32
  UploadApuPackages* = 0xC0AB06'u32
  WriteApuPort3Cmd57* = 0xC0AC01'u32
  WriteApuPort1Toggled* = 0xC0AC0C'u32
  ## Wait until APU port 0 is idle, then force current-song cache $B53B = $FFFF.
  # TODO: name this routine when it is adopted; only the wait+clear is known.
  WaitApuIdleClearSong* = 0xC0ABC6'u32
  WriteApuPort0* = 0xC0ABBD'u32
  ## WRAM: last song ID loaded (skip re-load when equal).
  CurrentSongId* = 0xB53B'u32
  ## WRAM: non-zero skips the warm-path port-3 $57 poke before a music change.
  # TODO: identify what $B4B6 gates beyond "already warm".
  MusicWarmFlag* = 0xB4B6'u32
  ## WRAM: cached pack indices for the three song-table slots (skip re-upload).
  CachedPack0* = 0xB53D'u32
  CachedPack1* = 0xB53F'u32
  CachedPack2* = 0xB541'u32
  ## WRAM: alternate pack-1 cache; pack slot 1 also skips when equal to this.
  # TODO: who writes $B543 and why it shadows CachedPack1.
  CachedPack1Alt* = 0xB543'u32
  ## WRAM: mask AND'd onto the pack address word before JSL $C0AB06.
  ## Prep helper forces $FFFF (full address); keep the name honest to the AND.
  ApuPackAddrMask* = 0xB547'u32
  ## Local DP frame size: TDC + #$FFEC (-20) before the body runs.
  LocalFrameAdj* = 0xFFEC'u32
  ## Song IDs $A0..$A7 skip the stop-music handshake (port1 toggle + wait idle).
  # TODO: confirm these IDs are ambient/SFX-layer tracks that keep the driver.
  SpecialSongIdLo* = 0x00A0'u32
  SpecialSongIdHi* = 0x00A7'u32
  ## Pack index $FF means "no pack" for that slot — skip upload.
  PackNone* = 0x00FF'u32
  One* = 0x0001'u32
  ## REP #$31: clear M, X, and C (16-bit A/X, carry clear for frame ADC).
  StatusMXC* = 0x31'u32
  ByteMask* = 0x00FF'u32

proc loadSong*(): seq[uint8] =
  ## Load a song by ID: resolve packs, upload changed packages, start playback.
  ##
  ## Entry (JSL): native mode; A = song ID. Builds a 20-byte DP frame, stores
  ## the ID in DP $12 / $B53B. If the ID matches the current song, returns
  ## immediately. Otherwise optionally pokes APU port 3 with $57 (warm path),
  ## and for non-special IDs stops the resident driver (port1 toggle + wait
  ## idle) before re-uploading.
  ##
  ## For each of the three song-table pack indices (bytes 0, 1, 2 at
  ## $C4F70A + (id-1)*3): if the index is not $FF and differs from the
  ## cached slot, index the pack table at $C4F947 (stride 3 → [bank, addr]),
  ## JSR the $C4FB42 mask helper, then JSL uploadApuPackages ($C0AB06) with
  ## A = address and X = bank.
  ##
  ## Tail: A = (id-1)+1 = song ID, JSL writeApuPort0 ($C0ABBD) to poke the
  ## play command on $2140, PLD, RTL.
  ##
  ## Evidence: docs/audio.md song table / pack table / $C0AB06 path; call sites
  ## pass song IDs then JSL $C4FBBD; three LDA $C4F70A,X at +0/+1/+2 with
  ## (id-1)*3; three JSL $C0AB06 after pack-table far-pointer walks.
  snesAsm(LoadSongSnes, NativeFlags16):
    rep StatusMXC
    phd
    pha
    tdc
    adc LocalFrameAdj
    tcd
    pla
    tax
    stx dp 0x12
    cpx abs CurrentSongId
    bne "notSameSong"
    jmp "exit"
    label "notSameSong"
    lda abs MusicWarmFlag
    bne "afterWarmPoke"
    jsl long WriteApuPort3Cmd57
    label "afterWarmPoke"
    ldx dp 0x12
    cpx SpecialSongIdLo
    bcc "stopMusic"
    cpx SpecialSongIdHi
    bcc "afterStopMusic"
    beq "afterStopMusic"
    label "stopMusic"
    lda One
    jsl long WriteApuPort1Toggled
    jsl long WaitApuIdleClearSong
    label "afterStopMusic"
    ldx dp 0x12
    stx abs CurrentSongId
    txy
    dey
    sty dp 0x10
    tya
    sta dp 0x4
    asl a
    adc dp 0x4
    tax
    lda longx SongTableBase
    andOp ByteMask
    sta dp 0xE
    cmp abs CachedPack0
    beq "pack0Done"
    cmp PackNone
    beq "pack0Done"
    sta abs CachedPack0
    lda PackTableAddr
    sta dp 0x6
    lda PackTableBank
    sta dp 0x8
    lda dp 0xE
    sta dp 0x4
    asl a
    adc dp 0x4
    sta dp 0x2
    ldx dp 0x6
    stx dp 0xA
    ldx dp 0x8
    stx dp 0xC
    clc
    adc dp 0xA
    sta dp 0xA
    lda dpil 0xA
    andOp ByteMask
    jsr abs PrepPackBankHelper
    tax
    lda dp 0x2
    inc a
    clc
    adc dp 0x6
    sta dp 0x6
    lda dpil 0x6
    andOp abs ApuPackAddrMask
    jsl long UploadApuPackages
    label "pack0Done"
    ldy dp 0x10
    tya
    sta dp 0x4
    asl a
    adc dp 0x4
    tax
    inx
    lda longx SongTableBase
    andOp ByteMask
    sta dp 0xE
    cmp abs CachedPack1
    beq "pack1Done"
    cmp PackNone
    beq "pack1Done"
    cmp abs CachedPack1Alt
    beq "pack1Done"
    sta abs CachedPack1
    lda PackTableAddr
    sta dp 0x6
    lda PackTableBank
    sta dp 0x8
    lda dp 0xE
    sta dp 0x4
    asl a
    adc dp 0x4
    sta dp 0x2
    ldx dp 0x6
    stx dp 0xA
    ldx dp 0x8
    stx dp 0xC
    clc
    adc dp 0xA
    sta dp 0xA
    lda dpil 0xA
    andOp ByteMask
    jsr abs PrepPackBankHelper
    tax
    lda dp 0x2
    inc a
    clc
    adc dp 0x6
    sta dp 0x6
    lda dpil 0x6
    andOp abs ApuPackAddrMask
    jsl long UploadApuPackages
    label "pack1Done"
    ldy dp 0x10
    tya
    sta dp 0x4
    asl a
    adc dp 0x4
    tax
    inx
    inx
    lda longx SongTableBase
    andOp ByteMask
    sta dp 0xE
    cmp abs CachedPack2
    beq "pack2Done"
    cmp PackNone
    beq "pack2Done"
    sta abs CachedPack2
    lda PackTableAddr
    sta dp 0x6
    lda PackTableBank
    sta dp 0x8
    lda dp 0xE
    sta dp 0x4
    asl a
    adc dp 0x4
    sta dp 0x2
    ldx dp 0x6
    stx dp 0xA
    ldx dp 0x8
    stx dp 0xC
    clc
    adc dp 0xA
    sta dp 0xA
    lda dpil 0xA
    andOp ByteMask
    jsr abs PrepPackBankHelper
    tax
    lda dp 0x2
    inc a
    clc
    adc dp 0x6
    sta dp 0x6
    lda dpil 0x6
    andOp abs ApuPackAddrMask
    jsl long UploadApuPackages
    label "pack2Done"
    ldy dp 0x10
    tya
    inc a
    jsl long WriteApuPort0
    label "exit"
    pld
    rtl
