## ROM header generation for Earthbound.

import
  ./common

proc generateEarthboundHeader*(): seq[uint8] =
  ## Generate the Earthbound ROM header based on reverse-engineered knowledge.
  ## This header is built from our understanding of what Earthbound's header should contain.
  ## The header at 0xFFB0 is 64 bytes, with the standard SNES header starting at 0xFFC0 (offset 0x10).
  result = newSeq[uint8](HeaderSize)
  
  for i in 0..<result.len:
    result[i] = 0
  
  # Pre-header region (0xFFB0-0xFFBF, offsets 0x00-0x0F)
  # TODO: Reverse engineer what these bytes represent. Possibly cartridge-specific metadata.
  result[0x00] = 0x30  # TODO: Determine meaning of 0x30
  result[0x01] = 0x31  # TODO: Determine meaning of 0x31
  result[0x02] = 0x4D  # TODO: Determine meaning of 0x4D
  result[0x03] = 0x42  # TODO: Determine meaning of 0x42
  result[0x04] = 0x20  # TODO: Determine meaning of 0x20 (space character?)
  result[0x05] = 0x20  # TODO: Determine meaning of 0x20 (space character?)
  
  # Standard SNES header starts at 0xFFC0 (offset 0x10)
  # Game title: 21 bytes, ASCII, null-padded
  let gameTitle = "EARTH BOUND     "
  let titleOffset = 0x10
  
  for i in 0..<gameTitle.len:
    if i + titleOffset < result.len:
      result[i + titleOffset] = gameTitle[i].uint8
  
  # Make code and game code region (offsets 0x20-0x24)
  # TODO: Reverse engineer make code format. These appear to be space characters (0x20).
  result[0x20] = 0x20  # TODO: Determine make code byte 1
  result[0x21] = 0x20  # TODO: Determine make code byte 2
  result[0x22] = 0x20  # TODO: Determine game code byte 1
  result[0x23] = 0x20  # TODO: Determine game code byte 2
  result[0x24] = 0x20  # TODO: Determine game code byte 3
  
  # ROM configuration and metadata (offsets 0x25-0x2F)
  result[0x25] = 0x31  # TODO: Reverse engineer ROM size/configuration byte
  result[0x26] = 0x02  # TODO: Reverse engineer cartridge type/subnumber (low byte)
  result[0x27] = 0x0C  # TODO: Reverse engineer cartridge type/subnumber (high byte)
  result[0x28] = 0x03  # TODO: Reverse engineer RAM size
  result[0x29] = 0x01  # TODO: Reverse engineer country code
  result[0x2A] = 0x33  # TODO: Reverse engineer fixed value (0x33 is common)
  result[0x2B] = 0x00  # TODO: Reverse engineer licensee code (low byte)
  result[0x2C] = 0xB7  # TODO: Reverse engineer checksum complement (low byte)
  result[0x2D] = 0xBF  # TODO: Reverse engineer checksum complement (high byte)
  result[0x2E] = 0x48  # TODO: Reverse engineer checksum (low byte)
  result[0x2F] = 0x40  # TODO: Reverse engineer checksum (high byte)
  
  # Native mode interrupt vectors (offsets 0x34-0x3B)
  # These are 16-bit addresses pointing to interrupt handlers in native mode
  result[0x34] = 0xFF  # Native mode RESET vector (low byte) - points to 0x5FFF
  result[0x35] = 0x5F  # Native mode RESET vector (high byte)
  # TODO: Reverse engineer what handler is at 0x5FFF
  result[0x36] = 0xFF  # Native mode IRQ vector (low byte) - points to 0x5FFF
  result[0x37] = 0x5F  # Native mode IRQ vector (high byte)
  # TODO: Reverse engineer what IRQ handler does at 0x5FFF
  result[0x38] = 0xFF  # Native mode unused vector (low byte) - points to 0x5FFF
  result[0x39] = 0x5F  # Native mode unused vector (high byte)
  # TODO: Determine if this vector is actually used
  result[0x3A] = 0x47  # Native mode BRK vector (low byte) - points to 0x8147
  result[0x3B] = 0x81  # Native mode BRK vector (high byte)
  # TODO: Reverse engineer BRK handler at 0x8147
  
  # Emulation mode interrupt vectors (offsets 0x3C-0x3F)
  result[0x3C] = 0x00  # Emulation mode ABORT vector (low byte) - points to 0x0000
  result[0x3D] = 0x00  # Emulation mode ABORT vector (high byte)
  # TODO: Determine if ABORT vector is used (0x0000 suggests unused)
  result[0x3E] = 0x4B  # Emulation mode RESET vector (low byte) - points to 0x814B
  result[0x3F] = 0x81  # Emulation mode RESET vector (high byte)
  # TODO: Reverse engineer emulation mode reset handler at 0x814B

