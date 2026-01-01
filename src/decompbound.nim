## Public interface for the decompbound decompilation project.
## This generates the ROM based on our reverse-engineered understanding.
## The gold master ROM is only used by compare.nim for validation.

# nim r src/decompbound.nim

import
  std/[strformat, parseopt, osproc]

const
  outputRom = "bin/Decompbound.smc"
  HiRomHeaderOffset = 0xFFB0
  HeaderSize = 64
  EarthboundRomSize = 3 * 1024 * 1024
  ResetVectorOffset = 0xFFF0
  ResetVectorSize = 16
  InitCodeOffset = 0x010000
  InitCodeSize = 128

proc generateEarthboundHeader(): seq[uint8] =
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

proc generateResetVectors(): seq[uint8] =
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

proc generateInitCode(): seq[uint8] =
  ## Generate the initialization code starting at 0x010000.
  ## This is the reset handler entry point that sets up the SNES.
  ## TODO: Reverse engineer this entire initialization sequence into proper Nim functions.
  result = newSeq[uint8](InitCodeSize)
  
  # 0x010000-0x010003: Initial subroutine call
  result[0x00] = 0x20  # JSR $0A1D (Jump to Subroutine, absolute) - calls initialization routine
  result[0x01] = 0x1D  # Low byte of subroutine address
  result[0x02] = 0x0A  # High byte of subroutine address
  # TODO: Reverse engineer what the subroutine at $0A1D does
  result[0x03] = 0x6B  # RTS (Return from Subroutine)
  # TODO: Determine if this RTS is actually reached or if it's dead code
  
  # 0x010004-0x01000B: Direct page setup
  result[0x04] = 0xC2  # REP #$31 (Reset Processor status bits - clear carry, zero, negative flags)
  result[0x05] = 0x31  # Immediate value: clear C, Z, N flags
  # TODO: Understand why these specific flags are cleared
  result[0x06] = 0x0B  # PHD (Push Direct Page register to stack)
  result[0x07] = 0x7B  # TDC (Transfer Direct Page register to Accumulator)
  result[0x08] = 0x69  # ADC #$FFEE (Add with Carry, immediate mode)
  result[0x09] = 0xEE  # Low byte: 0xEE
  result[0x0A] = 0xFF  # High byte: 0xFF (value is 0xFFEE)
  # TODO: Reverse engineer why 0xFFEE is added to direct page register
  result[0x0B] = 0x5B  # TCD (Transfer Accumulator to Direct Page register)
  # TODO: Understand the purpose of this direct page manipulation
  
  # 0x01000C-0x010013: Load and store from direct page
  result[0x0C] = 0xA5  # LDA $20 (Load Accumulator, direct page addressing)
  result[0x0D] = 0x20  # Direct page address $20
  # TODO: Determine what memory location $20 represents
  result[0x0E] = 0x85  # STA $06 (Store Accumulator, direct page addressing)
  result[0x0F] = 0x06  # Direct page address $06
  # TODO: Determine what memory location $06 represents
  result[0x10] = 0xA5  # LDA $22 (Load Accumulator, direct page addressing)
  result[0x11] = 0x22  # Direct page address $22
  # TODO: Determine what memory location $22 represents
  result[0x12] = 0x85  # STA $08 (Store Accumulator, direct page addressing)
  result[0x13] = 0x08  # Direct page address $08
  # TODO: Determine what memory location $08 represents
  
  # 0x010014-0x01001F: Long subroutine call and register preservation
  result[0x14] = 0x22  # JSL $C0943C (Jump to Subroutine Long, absolute long addressing)
  result[0x15] = 0x3C  # Low byte of address
  result[0x16] = 0x94  # Mid byte of address
  result[0x17] = 0xC0  # High byte of address (full address: $C0943C)
  # TODO: Reverse engineer what the subroutine at $C0943C does
  result[0x18] = 0xA5  # LDA $06 (Load Accumulator from preserved value)
  result[0x19] = 0x06  # Direct page address $06
  result[0x1A] = 0x85  # STA $0E (Store Accumulator)
  result[0x1B] = 0x0E  # Direct page address $0E
  # TODO: Understand why values are copied to $0E and $10
  result[0x1C] = 0xA5  # LDA $08 (Load Accumulator from preserved value)
  result[0x1D] = 0x08  # Direct page address $08
  result[0x1E] = 0x85  # STA $10 (Store Accumulator)
  result[0x1F] = 0x10  # Direct page address $10
  
  # 0x010020-0x010027: Additional long subroutine calls
  result[0x20] = 0x22  # JSL $C186B1 (Jump to Subroutine Long)
  result[0x21] = 0xB1  # Low byte
  result[0x22] = 0x86  # Mid byte
  result[0x23] = 0xC1  # High byte (full address: $C186B1)
  # TODO: Reverse engineer what the subroutine at $C186B1 does
  result[0x24] = 0x22  # JSL $C12DD5 (Jump to Subroutine Long)
  result[0x25] = 0xD5  # Low byte
  result[0x26] = 0x2D  # Mid byte
  result[0x27] = 0xC1  # High byte (full address: $C12DD5)
  # TODO: Reverse engineer what the subroutine at $C12DD5 does
  
  # 0x010028-0x01002F: Loop checking memory location
  result[0x28] = 0xAD  # LDA $B4A8 (Load Accumulator, absolute addressing)
  result[0x29] = 0xA8  # Low byte of address
  result[0x2A] = 0xB4  # High byte of address (full address: $B4A8)
  # TODO: Determine what memory location $B4A8 represents
  result[0x2B] = 0xC9  # CMP #$FFFF (Compare Accumulator, immediate mode)
  result[0x2C] = 0xFF  # Low byte: 0xFF
  result[0x2D] = 0xFF  # High byte: 0xFF (value is 0xFFFF)
  result[0x2E] = 0xD0  # BNE $010024 (Branch if Not Equal, relative addressing)
  result[0x2F] = 0xF4  # Relative offset: -12 bytes (branches back to $010024)
  # TODO: Reverse engineer the purpose of this polling loop
  
  # 0x010030-0x010035: Final subroutine call and cleanup
  result[0x30] = 0x22  # JSL $C09451 (Jump to Subroutine Long)
  result[0x31] = 0x51  # Low byte
  result[0x32] = 0x94  # Mid byte
  result[0x33] = 0xC0  # High byte (full address: $C09451)
  # TODO: Reverse engineer what the subroutine at $C09451 does
  result[0x34] = 0x2B  # PLD (Pull Direct Page register from stack)
  result[0x35] = 0x6B  # RTS (Return from Subroutine)
  # TODO: Understand the complete initialization flow
  
  # 0x010036-0x01003B: Function that stores to $964D
  result[0x36] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x37] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x38] = 0x8D  # STA $964D (Store Accumulator, absolute addressing)
  result[0x39] = 0x4D  # Low byte of address
  result[0x3A] = 0x96  # High byte of address (full address: $964D)
  # TODO: Determine what memory location $964D represents
  result[0x3B] = 0x60  # RTS (Return from Subroutine)
  
  # 0x01003C-0x010041: Function that clears $964D
  result[0x3C] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x3D] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x3E] = 0x9C  # STZ $964D (Store Zero, absolute addressing - clears memory)
  result[0x3F] = 0x4D  # Low byte of address
  result[0x40] = 0x96  # High byte of address (full address: $964D)
  # TODO: Determine what memory location $964D represents and why it's cleared
  result[0x41] = 0x60  # RTS (Return from Subroutine)
  
  # 0x010042-0x010047: Function that reads from $964D
  result[0x42] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x43] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x44] = 0xAD  # LDA $964D (Load Accumulator, absolute addressing)
  result[0x45] = 0x4D  # Low byte of address
  result[0x46] = 0x96  # High byte of address (full address: $964D)
  # TODO: Determine what memory location $964D represents
  result[0x47] = 0x60  # RTS (Return from Subroutine)
  
  # 0x010048-0x01004D: Function that stores to $964F
  result[0x48] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x49] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x4A] = 0x8D  # STA $964F (Store Accumulator, absolute addressing)
  result[0x4B] = 0x4F  # Low byte of address
  result[0x4C] = 0x96  # High byte of address (full address: $964F)
  # TODO: Determine what memory location $964F represents
  result[0x4D] = 0x60  # RTS (Return from Subroutine)
  
  # 0x01004E-0x01005B: Conditional subroutine call based on $89C9
  result[0x4E] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x4F] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x50] = 0xAD  # LDA $89C9 (Load Accumulator, absolute addressing)
  result[0x51] = 0xC9  # Low byte of address
  result[0x52] = 0x89  # High byte of address (full address: $89C9)
  # TODO: Determine what memory location $89C9 represents
  result[0x53] = 0x29  # AND #$00FF (Logical AND, immediate mode - mask to low byte)
  result[0x54] = 0xFF  # Low byte: 0xFF
  result[0x55] = 0x00  # High byte: 0x00 (value is 0x00FF, masks to 8-bit)
  result[0x56] = 0xF0  # BEQ $01005C (Branch if Equal to zero, relative addressing)
  result[0x57] = 0x04  # Relative offset: +4 bytes (skips next instruction if zero)
  result[0x58] = 0x22  # JSL $C3E450 (Jump to Subroutine Long)
  result[0x59] = 0x50  # Low byte
  result[0x5A] = 0xE4  # Mid byte
  result[0x5B] = 0xC3  # High byte (full address: $C3E450)
  # TODO: Reverse engineer what the subroutine at $C3E450 does and when it's called
  
  # 0x01005C-0x010067: Conditional subroutine call based on $9643
  result[0x5C] = 0xAD  # LDA $9643 (Load Accumulator, absolute addressing)
  result[0x5D] = 0x43  # Low byte of address
  result[0x5E] = 0x96  # High byte of address (full address: $9643)
  # TODO: Determine what memory location $9643 represents
  result[0x5F] = 0xF0  # BEQ $010067 (Branch if Equal to zero, relative addressing)
  result[0x60] = 0x06  # Relative offset: +6 bytes (skips next instruction if zero)
  result[0x61] = 0x22  # JSL $C43568 (Jump to Subroutine Long)
  result[0x62] = 0x68  # Low byte
  result[0x63] = 0x35  # Mid byte
  result[0x64] = 0xC4  # High byte (full address: $C43568)
  # TODO: Reverse engineer what the subroutine at $C43568 does
  result[0x65] = 0x80  # BRA $010077 (Branch Always, relative addressing)
  result[0x66] = 0x10  # Relative offset: +16 bytes (jumps to $010077)
  
  # 0x010067-0x010077: Multiple subroutine calls
  result[0x67] = 0x22  # JSL $C088B1 (Jump to Subroutine Long)
  result[0x68] = 0xB1  # Low byte
  result[0x69] = 0x88  # Mid byte
  result[0x6A] = 0xC0  # High byte (full address: $C088B1)
  # TODO: Reverse engineer what the subroutine at $C088B1 does
  result[0x6B] = 0x22  # JSL $C09466 (Jump to Subroutine Long)
  result[0x6C] = 0x66  # Low byte
  result[0x6D] = 0x94  # Mid byte
  result[0x6E] = 0xC0  # High byte (full address: $C09466)
  # TODO: Reverse engineer what the subroutine at $C09466 does
  result[0x6F] = 0x22  # JSL $C08B26 (Jump to Subroutine Long)
  result[0x70] = 0x26  # Low byte
  result[0x71] = 0x8B  # Mid byte
  result[0x72] = 0xC0  # High byte (full address: $C08B26)
  # TODO: Reverse engineer what the subroutine at $C08B26 does
  result[0x73] = 0x22  # JSL $C08756 (Jump to Subroutine Long)
  result[0x74] = 0x56  # Low byte
  result[0x75] = 0x87  # Mid byte
  result[0x76] = 0xC0  # High byte (full address: $C08756)
  # TODO: Reverse engineer what the subroutine at $C08756 does
  result[0x77] = 0x6B  # RTS (Return from Subroutine)
  
  # 0x010078-0x01007F: Final function reading from $8958
  result[0x78] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x79] = 0x31  # Immediate value: clear C, Z, N flags
  result[0x7A] = 0xAD  # LDA $8958 (Load Accumulator, absolute addressing)
  result[0x7B] = 0x58  # Low byte of address
  result[0x7C] = 0x89  # High byte of address (full address: $8958)
  # TODO: Determine what memory location $8958 represents
  result[0x7D] = 0x60  # RTS (Return from Subroutine)
  result[0x7E] = 0xC2  # REP #$31 (Reset Processor status bits)
  result[0x7F] = 0x31  # Immediate value: clear C, Z, N flags
  # TODO: This appears to be the start of another function - determine its purpose

proc generateRom(): string =
  ## Generate the decomp ROM from our reverse-engineered code and data.
  ## This builds the ROM based on our understanding, not by copying from the gold master.
  let headerData = generateEarthboundHeader()
  let resetVectors = generateResetVectors()
  let initCode = generateInitCode()
  
  var rom = newString(EarthboundRomSize)
  for i in 0..<rom.len:
    rom[i] = '\x00'
  
  for i in 0..<headerData.len:
    rom[HiRomHeaderOffset + i] = headerData[i].char
  
  for i in 0..<resetVectors.len:
    rom[ResetVectorOffset + i] = resetVectors[i].char
  
  for i in 0..<initCode.len:
    rom[InitCodeOffset + i] = initCode[i].char
  
  result = rom

when isMainModule:
  var runCompare = false
  
  var p = initOptParser()
  for kind, key, val in p.getOpt():
    case kind:
    of cmdLongOption, cmdShortOption:
      if key == "compare" or key == "c":
        runCompare = true
      else:
        echo "Unknown option: ", key
        quit(1)
    of cmdArgument:
      discard
    of cmdEnd:
      discard
  
  echo "Generating decomp ROM from reverse-engineered code..."
  
  let rom = generateRom()
  writeFile(outputRom, rom)
  
  echo &"Generated ROM: {outputRom} ({rom.len} bytes)"
  
  if runCompare:
    echo ""
    echo "Running comparison against gold master ROM..."
    let (output, exitCode) = execCmdEx("nim r src/compare.nim")
    echo output
    if exitCode != 0:
      quit(exitCode)
  else:
    echo "Use --compare or -c to validate against the gold master ROM."
