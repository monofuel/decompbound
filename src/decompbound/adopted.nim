## Hand-curated ROM regions that replace generated scaffolding.
## convert_all.nim carves these byte-ranges OUT of the traced code, so a curated
## module can sit MID-region (not only on a region boundary) and re-generation
## can never clobber it. Generated scaffold and adopted source therefore never
## overlap (tests/test_regions.nim enforces no-overlap + byte-exactness).
## See docs/goal-1.5.md.

import
  ./[sram_piracy, rng, apu_upload, cgram_dma_request, apu_port_io,
     song_loader, queue_apu_cmd, wait_apu_idle, bg_layer_setup,
     obj_base, bg4_bases, clear_wram_block, ppu_color_math, ppu_windows,
     ppu_scroll, mode7_mul, hdma_channel, hw_multiply]

proc allAdoptedRegions*(): seq[tuple[name: string, offset: int, data: seq[uint8]]] =
  ## Every hand-curated code region, assembled from named source.
  result.add (name: "sramMirrorPiracyCheck",
              offset: SramPiracyCheckOffset,
              data: sramMirrorPiracyCheck())
  result.add (name: "earthboundRandom",
              offset: RngAdvanceOffset,
              data: earthboundRandom())
  result.add (name: "uploadApuPackages",
              offset: ApuUploadOffset,
              data: uploadApuPackages())
  result.add (name: "requestCgramDma",
              offset: CgramDmaRequestOffset,
              data: requestCgramDma())
  result.add (name: "writeApuPort0",
              offset: WriteApuPort0Offset,
              data: writeApuPort0())
  result.add (name: "writeApuPort3Cmd57",
              offset: WriteApuPort3Cmd57Offset,
              data: writeApuPort3Cmd57())
  result.add (name: "writeApuPort1Toggled",
              offset: WriteApuPort1ToggleOffset,
              data: writeApuPort1Toggled())
  result.add (name: "loadSong",
              offset: LoadSongOffset,
              data: loadSong())
  result.add (name: "queueApuCommand",
              offset: QueueApuCmdOffset,
              data: queueApuCommand())
  result.add (name: "waitApuIdleClearSong",
              offset: WaitApuIdleClearSongOffset,
              data: waitApuIdleClearSong())
  result.add (name: "readApuPort0",
              offset: ReadApuPort0Offset,
              data: readApuPort0())
  result.add (name: "setBgMode",
              offset: SetBgModeOffset,
              data: setBgMode())
  result.add (name: "setObjBase",
              offset: SetObjBaseOffset,
              data: setObjBase())
  result.add (name: "setBg1Bases",
              offset: SetBg1BasesOffset,
              data: setBg1Bases())
  result.add (name: "setBg2Bases",
              offset: SetBg2BasesOffset,
              data: setBg2Bases())
  result.add (name: "setBg3Bases",
              offset: SetBg3BasesOffset,
              data: setBg3Bases())
  result.add (name: "setBg4Bases",
              offset: SetBg4BasesOffset,
              data: setBg4Bases())
  result.add (name: "clearWramBlock280C",
              offset: ClearWramBlock280COffset,
              data: clearWramBlock280C())
  result.add (name: "applyColorMathPreset",
              offset: ApplyColorMathPresetOffset,
              data: applyColorMathPreset())
  result.add (name: "setFixedColorRgb",
              offset: SetFixedColorRgbOffset,
              data: setFixedColorRgb())
  result.add (name: "writeColorMathRegs",
              offset: WriteColorMathRegsOffset,
              data: writeColorMathRegs())
  result.add (name: "configurePpuWindows",
              offset: ConfigurePpuWindowsOffset,
              data: configurePpuWindows())
  result.add (name: "resetWindowPositions",
              offset: ResetWindowPositionsOffset,
              data: resetWindowPositions())
  result.add (name: "flushBg3Vofs",
              offset: FlushBg3VofsOffset,
              data: flushBg3Vofs())
  result.add (name: "mode7MulBySine",
              offset: Mode7MulBySineOffset,
              data: mode7MulBySine())
  result.add (name: "clearHdmaEnableBit",
              offset: ClearHdmaEnableBitOffset,
              data: clearHdmaEnableBit())
  result.add (name: "setupHdmaChannelWh0",
              offset: SetupHdmaChannelWh0Offset,
              data: setupHdmaChannelWh0())
  result.add (name: "hardwareMultiply",
              offset: HardwareMultiplyOffset,
              data: hardwareMultiply())

proc adoptedRanges*(): seq[tuple[start: int, last: int]] =
  ## Inclusive file-offset spans owned by curated modules, derived from the
  ## assembled length of each. convert_all carves these out of the traced code.
  for r in allAdoptedRegions():
    result.add (start: r.offset, last: r.offset + r.data.len - 1)

proc isAdoptedOffset*(offset: int): bool =
  ## True when a file offset is owned by a curated module.
  for r in adoptedRanges():
    if offset >= r.start and offset <= r.last:
      return true
  result = false
