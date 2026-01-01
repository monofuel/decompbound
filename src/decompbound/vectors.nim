## Reset vector generation for Earthbound.

import
  ./common

proc generateResetVectors*(): seq[uint8] =
  ## Generate the reset vectors at 0xFFF0-0xFFFF.
  ## These vectors point to interrupt handlers and the reset entry point.
  ## In HiROM, these are at the end of bank 0x00, mapping to memory addresses 0x00FFF0-0x00FFFF.
  result = newSeq[uint8](ResetVectorSize)
  
  # Vector region 0xFFF0-0xFFFF (offsets 0x00-0x0F)
  # These are 16-bit little-endian addresses pointing to interrupt handlers
  
  # 0xFFF0-0xFFF1: Unused/Reserved
  result[0x00] = 0x00  # TODO: Determine if this vector is used
  result[0x01] = 0x00  # Points to 0x0000 (likely unused)
  
  # 0xFFF2-0xFFF3: Unused/Reserved
  result[0x02] = 0x00  # TODO: Determine if this vector is used
  result[0x03] = 0x00  # Points to 0x0000 (likely unused)
  
  # 0xFFF4-0xFFF5: Unused/Reserved vector
  result[0x04] = 0xFF  # TODO: Determine purpose of vector at 0x5FFF
  result[0x05] = 0x5F  # Points to 0x5FFF (same as many other vectors)
  
  # 0xFFF6-0xFFF7: Unused/Reserved
  result[0x06] = 0x00  # TODO: Determine if this vector is used
  result[0x07] = 0x00  # Points to 0x0000 (likely unused)
  
  # 0xFFF8-0xFFF9: Unused/Reserved vector
  result[0x08] = 0xFF  # TODO: Determine purpose of vector at 0x5FFF
  result[0x09] = 0x5F  # Points to 0x5FFF
  
  # 0xFFFA-0xFFFB: Unused/Reserved vector
  result[0x0A] = 0xFF  # TODO: Determine purpose of vector at 0x5FFF
  result[0x0B] = 0x5F  # Points to 0x5FFF
  
  # 0xFFFC-0xFFFD: Native mode RESET vector (primary reset entry point)
  result[0x0C] = 0x41  # Native mode RESET vector (low byte) - points to 0x8141
  result[0x0D] = 0x81  # Native mode RESET vector (high byte)
  # TODO: Reverse engineer the reset handler code at 0x8141. This is the main entry point.
  
  # 0xFFFE-0xFFFF: Emulation mode RESET vector
  result[0x0E] = 0xFF  # Emulation mode RESET vector (low byte) - points to 0x5FFF
  result[0x0F] = 0x5F  # Emulation mode RESET vector (high byte)
  # TODO: Reverse engineer emulation mode reset handler at 0x5FFF

