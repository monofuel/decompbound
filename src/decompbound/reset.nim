## Reset handler generation for Earthbound.
## This is the main reset entry point at 0x8141, called by the reset vector.

import
  ./common

proc generateResetHandler*(): seq[uint8] =
  ## Generate the reset handler code at 0x8141.
  ## This is the primary entry point when the SNES is reset or powered on.
  ## TODO: Reverse engineer this entire reset sequence into proper Nim functions.
  result = newSeq[uint8](ResetHandlerSize)
  
  # 0x8141-0x8150: Initial setup and register configuration
  result[0x00] = 0x18  # CLC (Clear Carry flag)
  result[0x01] = 0xFB  # XCE (Exchange Carry and Emulation flags)
  # TODO: Understand the purpose of clearing carry and exchanging flags
  result[0x02] = 0x5C  # JML $C00080 (Jump to Long, absolute long addressing)
  result[0x03] = 0x00  # Low byte of address
  result[0x04] = 0x80  # Mid byte of address
  result[0x05] = 0xC0  # High byte of address (full address: $C00080)
  # TODO: Reverse engineer what the code at $C00080 does
  result[0x06] = 0x5C  # JML $C08170 (Jump to Long)
  result[0x07] = 0x70  # Low byte
  result[0x08] = 0x81  # Mid byte
  result[0x09] = 0xC0  # High byte (full address: $C08170)
  # TODO: Reverse engineer what the code at $C08170 does
  result[0x0A] = 0x5C  # JML $C0814F (Jump to Long)
  result[0x0B] = 0x4F  # Low byte
  result[0x0C] = 0x81  # Mid byte
  result[0x0D] = 0xC0  # High byte (full address: $C0814F)
  # TODO: Reverse engineer what the code at $C0814F does
  result[0x0E] = 0x08  # PHP (Push Processor status to stack)
  result[0x0F] = 0xC2  # REP #$30 (Reset Processor status bits - clear carry, zero, negative flags)
  result[0x10] = 0x30  # Immediate value: clear C, Z, N flags
  
  # 0x8151-0x8160: Stack and register setup
  result[0x11] = 0x48  # PHA (Push Accumulator to stack)
  result[0x12] = 0xDA  # PHX (Push X register to stack)
  result[0x13] = 0x5A  # PHY (Push Y register to stack)
  result[0x14] = 0x0B  # PHD (Push Direct Page register to stack)
  result[0x15] = 0xF4  # PEA $0000 (Push Effective Address, immediate mode)
  result[0x16] = 0x00  # Low byte: 0x00
  result[0x17] = 0x00  # High byte: 0x00 (pushes 0x0000 to stack)
  # TODO: Understand why 0x0000 is pushed to stack
  result[0x18] = 0x2B  # PLD (Pull Direct Page register from stack)
  result[0x19] = 0x8B  # PHB (Push Data Bank register to stack)
  result[0x1A] = 0xF4  # PEA $0000 (Push Effective Address, immediate mode)
  result[0x1B] = 0x00  # Low byte: 0x00
  result[0x1C] = 0x00  # High byte: 0x00 (pushes 0x0000 to stack)
  result[0x1D] = 0xAB  # PLB (Pull Data Bank register from stack)
  result[0x1E] = 0xAB  # PLB (Pull Data Bank register from stack again)
  # TODO: Understand the purpose of double PLB
  result[0x1F] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0x20] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  
  # 0x8161-0x8170: Memory-mapped I/O configuration
  result[0x21] = 0xAD  # LDA $4211 (Load Accumulator, absolute addressing - read PPU status)
  result[0x22] = 0x11  # Low byte of address
  result[0x23] = 0x42  # High byte of address (full address: $4211 - PPU status register)
  # TODO: Understand why PPU status is read
  result[0x24] = 0x30  # BMI $8181 (Branch if Minus, relative addressing)
  result[0x25] = 0x1C  # Relative offset: +28 bytes (branches to $8181 if negative)
  result[0x26] = 0xC2  # REP #$30 (Reset Processor status bits)
  result[0x27] = 0x30  # Immediate value: clear C, Z, N flags
  result[0x28] = 0xAB  # PLB (Pull Data Bank register from stack)
  result[0x29] = 0x2B  # PLD (Pull Direct Page register from stack)
  result[0x2A] = 0x7A  # PLY (Pull Y register from stack)
  result[0x2B] = 0xFA  # PLX (Pull X register from stack)
  result[0x2C] = 0x68  # PLA (Pull Accumulator from stack)
  result[0x2D] = 0x28  # PLP (Pull Processor status from stack)
  result[0x2E] = 0x40  # RTI (Return from Interrupt)
  result[0x2F] = 0x08  # PHP (Push Processor status to stack)
  
  # 0x8171-0x8180: Additional setup
  result[0x30] = 0xC2  # REP #$30 (Reset Processor status bits)
  result[0x31] = 0x30  # Immediate value: clear C, Z, N flags
  result[0x32] = 0x48  # PHA (Push Accumulator to stack)
  result[0x33] = 0xDA  # PHX (Push X register to stack)
  result[0x34] = 0x5A  # PHY (Push Y register to stack)
  result[0x35] = 0x0B  # PHD (Push Direct Page register to stack)
  result[0x36] = 0xF4  # PEA $0000 (Push Effective Address, immediate mode)
  result[0x37] = 0x00  # Low byte: 0x00
  result[0x38] = 0x00  # High byte: 0x00 (pushes 0x0000 to stack)
  result[0x39] = 0x2B  # PLD (Pull Direct Page register from stack)
  result[0x3A] = 0x8B  # PHB (Push Data Bank register to stack)
  result[0x3B] = 0xF4  # PEA $0000 (Push Effective Address, immediate mode)
  result[0x3C] = 0x00  # Low byte: 0x00
  result[0x3D] = 0x00  # High byte: 0x00 (pushes 0x0000 to stack)
  result[0x3E] = 0xAB  # PLB (Pull Data Bank register from stack)
  result[0x3F] = 0xAB  # PLB (Pull Data Bank register from stack again)
  
  # 0x8181-0x8190: PPU and display configuration
  result[0x40] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0x41] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0x42] = 0xAD  # LDA $4210 (Load Accumulator, absolute addressing - read PPU status)
  result[0x43] = 0x10  # Low byte of address
  result[0x44] = 0x42  # High byte of address (full address: $4210 - PPU status register)
  result[0x45] = 0x9C  # STZ $420C (Store Zero, absolute addressing - disable HDMA)
  result[0x46] = 0x0C  # Low byte of address
  result[0x47] = 0x42  # High byte of address (full address: $420C - HDMA enable register)
  # TODO: Understand why HDMA is disabled
  result[0x48] = 0xA9  # LDA #$80 (Load Accumulator, immediate mode)
  result[0x49] = 0x80  # Immediate value: 0x80
  result[0x4A] = 0x8D  # STA $2100 (Store Accumulator, absolute addressing - set screen brightness)
  result[0x4B] = 0x00  # Low byte of address
  result[0x4C] = 0x21  # High byte of address (full address: $2100 - INIDISP register)
  # TODO: Understand screen brightness configuration (0x80 = forced blank)
  result[0x4D] = 0xE6  # INC $2B (Increment, direct page addressing)
  result[0x4E] = 0x2B  # Direct page address $2B
  # TODO: Determine what memory location $2B represents
  result[0x4F] = 0xE6  # INC $02 (Increment, direct page addressing)
  result[0x50] = 0x02  # Direct page address $02
  # TODO: Determine what memory location $02 represents
  
  # 0x8191-0x81A0: DMA configuration
  result[0x51] = 0xC2  # REP #$20 (Reset Processor status bits - set accumulator to 16-bit)
  result[0x52] = 0x20  # Immediate value: clear M flag (16-bit accumulator)
  result[0x53] = 0xE2  # SEP #$10 (Set Processor status bits - set index registers to 8-bit)
  result[0x54] = 0x10  # Immediate value: set X flag (8-bit index registers)
  result[0x55] = 0xA6  # LDX $2C (Load X register, direct page addressing)
  result[0x56] = 0x2C  # Direct page address $2C
  # TODO: Determine what memory location $2C represents
  result[0x57] = 0xF0  # BEQ $81C1 (Branch if Equal to zero, relative addressing)
  result[0x58] = 0x2E  # Relative offset: +46 bytes (branches to $81C1 if zero)
  result[0x59] = 0xA0  # LDY #$00 (Load Y register, immediate mode)
  result[0x5A] = 0x00  # Immediate value: 0x00
  result[0x5B] = 0x9C  # STZ $2102 (Store Zero, absolute addressing - clear OAM address)
  result[0x5C] = 0x02  # Low byte of address
  result[0x5D] = 0x21  # High byte of address (full address: $2102 - OAMADDL register)
  # TODO: Understand OAM (Object Attribute Memory) configuration
  result[0x5E] = 0x8C  # STY $2103 (Store Y register, absolute addressing - set OAM address high)
  result[0x5F] = 0x00  # TODO: Determine meaning of 0x00
  result[0x60] = 0x43  # TODO: Determine meaning of 0x43
  result[0x61] = 0x8C  # STY $4304 (Store Y register, absolute addressing)
  result[0x62] = 0x04  # Low byte of address
  result[0x63] = 0x43  # High byte of address (full address: $4304 - DMAB1 register)
  # TODO: Understand DMA bank configuration
  result[0x64] = 0xA0  # LDY #$04 (Load Y register, immediate mode)
  result[0x65] = 0x04  # Immediate value: 0x04
  result[0x66] = 0x8C  # STY $4301 (Store Y register, absolute addressing - set DMA destination)
  result[0x67] = 0x01  # Low byte of address
  result[0x68] = 0x43  # High byte of address (full address: $4301 - DMAP1 register)
  result[0x69] = 0xA9  # LDA #$0005 (Load Accumulator, immediate mode)
  result[0x6A] = 0x00  # Low byte: 0x00
  result[0x6B] = 0x05  # High byte: 0x05 (value is 0x0500)
  # TODO: Understand why 0x0500 is loaded
  result[0x6C] = 0xA6  # LDX $2C (Load X register, direct page addressing)
  result[0x6D] = 0x2C  # Direct page address $2C
  result[0x6E] = 0xCA  # DEX (Decrement X register)
  result[0x6F] = 0xF0  # BEQ $81B4 (Branch if Equal to zero, relative addressing)
  result[0x70] = 0x03  # Relative offset: +3 bytes (branches to $81B4 if zero)
  result[0x71] = 0xA9  # LDA #$0000 (Load Accumulator, immediate mode)
  result[0x72] = 0x00  # Low byte: 0x00
  result[0x73] = 0x08  # High byte: 0x08 (value is 0x0800)
  # TODO: Understand why 0x0800 is loaded
  result[0x74] = 0x8D  # STA $4302 (Store Accumulator, absolute addressing - set DMA destination)
  result[0x75] = 0x02  # Low byte of address
  result[0x76] = 0x43  # High byte of address (full address: $4302 - DMAP1 register)
  # TODO: Understand DMA channel 1 configuration
  result[0x77] = 0xA9  # LDA #$0220 (Load Accumulator, immediate mode)
  result[0x78] = 0x20  # Low byte: 0x20
  result[0x79] = 0x02  # High byte: 0x02 (value is 0x0220)
  # TODO: Understand why 0x0220 is loaded
  result[0x7A] = 0x8D  # STA $4305 (Store Accumulator, absolute addressing - set DMA size)
  result[0x7B] = 0x05  # Low byte of address
  result[0x7C] = 0x43  # High byte of address (full address: $4305 - DMASIZEL register)
  # TODO: Understand DMA transfer size configuration
  result[0x7D] = 0xA0  # LDY #$01 (Load Y register, immediate mode)
  result[0x7E] = 0x01  # Immediate value: 0x01
  result[0x7F] = 0x8C  # STY $420B (Store Y register, absolute addressing - enable DMA channel 1)
  # Note: Reset handler continues beyond 128 bytes at 0x81C1
  # TODO: Implement remaining bytes of reset handler if needed
  # Note: Reset handler continues beyond 128 bytes at 0x81C1
  # TODO: Implement remaining bytes of reset handler if needed

