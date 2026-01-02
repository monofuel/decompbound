## Common constants and types for the decompbound project.
## This module should not import other decompbound files.

const
  outputRom* = "bin/Decompbound.smc"
  HiRomHeaderOffset* = 0xFFB0
  HeaderSize* = 64
  EarthboundRomSize* = 3 * 1024 * 1024
  ResetVectorOffset* = 0xFFF0
  ResetVectorSize* = 16
  InitCodeOffset* = 0x010000
  InitCodeSize* = 256
  ResetHandlerOffset* = 0x8141
  ResetHandlerSize* = 512
  BrkHandlerOffset* = 0x8147
  BrkHandlerSize* = 128
  EarlySubroutineOffset* = 0x0A1D
  EarlySubroutineSize* = 256
