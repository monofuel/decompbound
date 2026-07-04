## Common constants and types for the decompbound project.
## This module should not import other decompbound files.

const
  outputRom* = "bin/Decompbound.smc"
  HiRomHeaderOffset* = 0xFFB0
  HeaderSize* = 64
  EarthboundRomSize* = 3 * 1024 * 1024
  ResetVectorOffset* = 0xFFF0
  ResetVectorSize* = 16
