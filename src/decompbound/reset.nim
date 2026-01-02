## Reset handler generation for Earthbound.
## This is the main reset entry point at 0x8141, called by the reset vector.

import
  ./common

proc generateResetHandler*(): seq[uint8] =
  ## Generate the reset handler code at 0x8141.
  ## This is the primary entry point when the SNES is reset or powered on.
  ## TODO: Reverse engineer this entire reset sequence into proper Nim functions.
  result = newSeq[uint8](ResetHandlerSize)
  
  # Reset handler spans 0x8141-0x8340 (384 bytes total)
  
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
  
  # 0x81C1-0x81D0: DMA continuation and register operations
  result[0x80] = 0x0B  # TODO: Determine meaning of 0x0B
  result[0x81] = 0x42  # TODO: Determine meaning of 0x42
  result[0x82] = 0x18  # CLC (Clear Carry flag)
  result[0x83] = 0x65  # ADC $99 (Add with Carry, direct page addressing)
  result[0x84] = 0x99  # Direct page address $99
  # TODO: Determine what memory location $99 represents
  result[0x85] = 0x85  # STA $99 (Store Accumulator, direct page addressing)
  result[0x86] = 0x99  # Direct page address $99
  result[0x87] = 0xAE  # LDX $0030 (Load X register, absolute addressing)
  result[0x88] = 0x30  # Low byte of address
  result[0x89] = 0x00  # High byte of address (full address: $0030)
  # TODO: Determine what memory location $0030 represents
  result[0x8A] = 0xF0  # BEQ $81B6 (Branch if Equal to zero, relative addressing)
  result[0x8B] = 0x2A  # Relative offset: +42 bytes (branches to $81B6 if zero)
  result[0x8C] = 0xBD  # LDA $8F94,X (Load Accumulator, absolute indexed X)
  result[0x8D] = 0x94  # Low byte of address
  result[0x8E] = 0x8F  # High byte of address (full address: $8F94)
  # TODO: Determine what memory location $8F94 represents and the purpose of indexing
  result[0x8F] = 0x8D  # STA $4302 (Store Accumulator, absolute addressing - set DMA destination)
  result[0x90] = 0x02  # Low byte of address
  result[0x91] = 0x43  # High byte of address (full address: $4302 - DMAP1 register)
  result[0x92] = 0xBC  # LDY $8F96,X (Load Y register, absolute indexed X)
  result[0x93] = 0x96  # Low byte of address
  result[0x94] = 0x8F  # High byte of address (full address: $8F96)
  # TODO: Determine what memory location $8F96 represents
  result[0x95] = 0x8C  # STY $2121 (Store Y register, absolute addressing)
  result[0x96] = 0x21  # Low byte of address
  result[0x97] = 0x21  # High byte of address (full address: $2121 - CGADD register)
  # TODO: Understand CGRAM (Color Generator RAM) address configuration
  
  # 0x81D1-0x81E0: Additional DMA and memory operations
  result[0x98] = 0xA9  # LDA #$2200 (Load Accumulator, immediate mode)
  result[0x99] = 0x00  # Low byte: 0x00
  result[0x9A] = 0x22  # High byte: 0x22 (value is 0x2200)
  # TODO: Understand why 0x2200 is loaded
  result[0x9B] = 0x8D  # STA $4300 (Store Accumulator, absolute addressing - set DMA mode)
  result[0x9C] = 0x00  # Low byte of address
  result[0x9D] = 0x43  # High byte of address (full address: $4300 - DMAP1 register)
  # TODO: Understand DMA mode configuration (0x2200)
  result[0x9E] = 0xA0  # LDY #$00 (Load Y register, immediate mode)
  result[0x9F] = 0x00  # Immediate value: 0x00
  result[0xA0] = 0x8C  # STY $4304 (Store Y register, absolute addressing - set DMA bank)
  result[0xA1] = 0x04  # Low byte of address
  result[0xA2] = 0x43  # High byte of address (full address: $4304 - DMAB1 register)
  result[0xA3] = 0x8C  # STY $0030 (Store Y register, absolute addressing)
  result[0xA4] = 0x30  # Low byte of address
  result[0xA5] = 0x00  # High byte of address (full address: $0030)
  result[0xA6] = 0xBD  # LDA $8F92,X (Load Accumulator, absolute indexed X)
  result[0xA7] = 0x92  # Low byte of address
  result[0xA8] = 0x8F  # High byte of address (full address: $8F92)
  # TODO: Determine what memory location $8F92 represents
  result[0xA9] = 0x8D  # STA $4305 (Store Accumulator, absolute addressing - set DMA size)
  result[0xAA] = 0x05  # Low byte of address
  result[0xAB] = 0x43  # High byte of address (full address: $4305 - DMASIZEL register)
  result[0xAC] = 0xA0  # LDY #$01 (Load Y register, immediate mode)
  result[0xAD] = 0x01  # Immediate value: 0x01
  result[0xAE] = 0x8C  # STY $420B (Store Y register, absolute addressing - enable DMA channel 1)
  result[0xAF] = 0x0B  # Low byte of address
  result[0xB0] = 0x42  # High byte of address (full address: $420B - MDMAEN register)
  
  # 0x81E1-0x81F0: Register manipulation and conditional logic
  result[0xB1] = 0x18  # CLC (Clear Carry flag)
  result[0xB2] = 0x65  # ADC $99 (Add with Carry, direct page addressing)
  result[0xB3] = 0x99  # Direct page address $99
  result[0xB4] = 0x85  # STA $99 (Store Accumulator, direct page addressing)
  result[0xB5] = 0x99  # Direct page address $99
  result[0xB6] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0xB7] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0xB8] = 0xA5  # LDA $28 (Load Accumulator, direct page addressing)
  result[0xB9] = 0x28  # Direct page address $28
  # TODO: Determine what memory location $28 represents
  result[0xBA] = 0xF0  # BEQ $81DE (Branch if Equal to zero, relative addressing)
  result[0xBB] = 0x22  # Relative offset: +34 bytes (branches to $81DE if zero)
  result[0xBC] = 0xC6  # DEC $2A (Decrement, direct page addressing)
  result[0xBD] = 0x2A  # Direct page address $2A
  # TODO: Determine what memory location $2A represents
  result[0xBE] = 0x10  # BPL $81DE (Branch if Plus, relative addressing)
  result[0xBF] = 0x1E  # Relative offset: +30 bytes (branches to $81DE if positive)
  
  # 0x81F1-0x8200: Memory operations and conditional logic
  result[0xC0] = 0xA5  # LDA $29 (Load Accumulator, direct page addressing)
  result[0xC1] = 0x29  # Direct page address $29
  # TODO: Determine what memory location $29 represents
  result[0xC2] = 0x85  # STA $2A (Store Accumulator, direct page addressing)
  result[0xC3] = 0x2A  # Direct page address $2A
  result[0xC4] = 0xA5  # LDA $0D (Load Accumulator, direct page addressing)
  result[0xC5] = 0x0D  # Direct page address $0D
  # TODO: Determine what memory location $0D represents
  result[0xC6] = 0x29  # AND #$0F (Logical AND, immediate mode)
  result[0xC7] = 0x0F  # Immediate value: 0x0F (masks to low 4 bits)
  result[0xC8] = 0x18  # CLC (Clear Carry flag)
  result[0xC9] = 0x65  # ADC $28 (Add with Carry, direct page addressing)
  result[0xCA] = 0x28  # Direct page address $28
  result[0xCB] = 0x10  # BPL $81D4 (Branch if Plus, relative addressing)
  result[0xCC] = 0x07  # Relative offset: +7 bytes (branches to $81D4 if positive)
  result[0xCD] = 0x9C  # STZ $001F (Store Zero, absolute addressing - clears memory)
  result[0xCE] = 0x1F  # Low byte of address
  result[0xCF] = 0x00  # High byte of address (full address: $001F)
  # TODO: Determine what memory location $001F represents
  result[0xD0] = 0xA9  # LDA #$80 (Load Accumulator, immediate mode)
  result[0xD1] = 0x80  # Immediate value: 0x80
  result[0xD2] = 0x80  # BRA $81DA (Branch Always, relative addressing)
  result[0xD3] = 0x06  # Relative offset: +6 bytes (jumps to $81DA)
  
  # 0x8201-0x8210: Conditional value assignment
  result[0xD4] = 0xC9  # CMP #$10 (Compare Accumulator, immediate mode)
  result[0xD5] = 0x10  # Immediate value: 0x10
  result[0xD6] = 0x90  # BCC $81D7 (Branch if Carry Clear, relative addressing)
  result[0xD7] = 0x04  # Relative offset: +4 bytes (branches to $81D7 if carry clear)
  result[0xD8] = 0xA9  # LDA #$0F (Load Accumulator, immediate mode)
  result[0xD9] = 0x0F  # Immediate value: 0x0F
  result[0xDA] = 0x64  # STZ $28 (Store Zero, direct page addressing - clears memory)
  result[0xDB] = 0x28  # Direct page address $28
  result[0xDC] = 0x85  # STA $0D (Store Accumulator, direct page addressing)
  result[0xDD] = 0x0D  # Direct page address $0D
  result[0xDE] = 0xC2  # REP #$10 (Reset Processor status bits - set index registers to 16-bit)
  result[0xDF] = 0x10  # Immediate value: clear X flag (16-bit index registers)
  
  # 0x8211-0x8220: PPU register configuration
  result[0xE0] = 0xA5  # LDA $0D (Load Accumulator, direct page addressing)
  result[0xE1] = 0x0D  # Direct page address $0D
  result[0xE2] = 0x8D  # STA $2100 (Store Accumulator, absolute addressing - set screen brightness)
  result[0xE3] = 0x00  # Low byte of address
  result[0xE4] = 0x21  # High byte of address (full address: $2100 - INIDISP register)
  # TODO: Understand screen brightness configuration
  result[0xE5] = 0xA5  # LDA $10 (Load Accumulator, direct page addressing)
  result[0xE6] = 0x10  # Direct page address $10
  # TODO: Determine what memory location $10 represents
  result[0xE7] = 0x8D  # STA $2106 (Store Accumulator, absolute addressing - set mosaic register)
  result[0xE8] = 0x06  # Low byte of address
  result[0xE9] = 0x21  # High byte of address (full address: $2106 - MOSAIC register)
  # TODO: Understand mosaic effect configuration
  result[0xEA] = 0xA4  # LDY $15 (Load Y register, direct page addressing)
  result[0xEB] = 0x15  # Direct page address $15
  # TODO: Determine what memory location $15 represents
  result[0xEC] = 0x8C  # STY $210B (Store Y register, absolute addressing - set BG tile base)
  result[0xED] = 0x0B  # Low byte of address
  result[0xEE] = 0x21  # High byte of address (full address: $210B - BG12NBA register)
  # TODO: Understand background tile base configuration
  
  # 0x8221-0x8230: Additional PPU configuration
  result[0xEF] = 0xA4  # LDY $17 (Load Y register, direct page addressing)
  result[0xF0] = 0x17  # Direct page address $17
  # TODO: Determine what memory location $17 represents
  result[0xF1] = 0xA0  # LDY #$00FF (Load Y register, immediate mode)
  result[0xF2] = 0xFF  # Low byte: 0xFF
  result[0xF3] = 0x00  # High byte: 0x00 (value is 0x00FF)
  result[0xF4] = 0x8C  # STY $2128 (Store Y register, absolute addressing)
  result[0xF5] = 0x28  # Low byte of address
  result[0xF6] = 0x21  # High byte of address (full address: $2128 - WOBJSEL register)
  # TODO: Understand window object selection configuration
  result[0xF7] = 0xC2  # REP #$20 (Reset Processor status bits - set accumulator to 16-bit)
  result[0xF8] = 0x20  # Immediate value: clear M flag (16-bit accumulator)
  result[0xF9] = 0xE2  # SEP #$10 (Set Processor status bits - set index registers to 8-bit)
  result[0xFA] = 0x10  # Immediate value: set X flag (8-bit index registers)
  result[0xFB] = 0xA6  # LDX $01 (Load X register, direct page addressing)
  result[0xFC] = 0x01  # Direct page address $01
  # TODO: Determine what memory location $01 represents
  result[0xFD] = 0x80  # BRA $8235 (Branch Always, relative addressing)
  result[0xFE] = 0x32  # Relative offset: +50 bytes (jumps to $8235)
  result[0xFF] = 0xBC  # LDY $8FBC,X (Load Y register, absolute indexed X)
  
  # 0x8241-0x8250: Memory operations and DMA configuration
  result[0x100] = 0x00  # TODO: Determine meaning of 0x00
  result[0x101] = 0x04  # TODO: Determine meaning of 0x04
  result[0x102] = 0xB9  # LDA $8FB0,Y (Load Accumulator, absolute indexed Y)
  result[0x103] = 0xB0  # Low byte of address
  result[0x104] = 0x8F  # High byte of address (full address: $8FB0)
  # TODO: Determine what memory location $8FB0 represents
  result[0x105] = 0x8D  # STA $4300 (Store Accumulator, absolute addressing - set DMA mode)
  result[0x106] = 0x00  # Low byte of address
  result[0x107] = 0x43  # High byte of address (full address: $4300 - DMAP1 register)
  result[0x108] = 0xB9  # LDA $8FB2,Y (Load Accumulator, absolute indexed Y)
  result[0x109] = 0xB2  # Low byte of address
  result[0x10A] = 0x8F  # High byte of address (full address: $8FB2)
  # TODO: Determine what memory location $8FB2 represents
  result[0x10B] = 0x8D  # STA $2115 (Store Accumulator, absolute addressing - set VRAM increment)
  result[0x10C] = 0x15  # Low byte of address
  result[0x10D] = 0x21  # High byte of address (full address: $2115 - VMAIN register)
  # TODO: Understand VRAM increment configuration
  result[0x10E] = 0xBD  # LDA $0401,X (Load Accumulator, direct page indexed X)
  result[0x10F] = 0x01  # Low byte of address
  result[0x110] = 0x04  # High byte of address (full address: $0401)
  # TODO: Determine what memory location $0401 represents
  
  # 0x8251-0x8260: DMA source and destination configuration
  result[0x111] = 0x8D  # STA $4305 (Store Accumulator, absolute addressing - set DMA size)
  result[0x112] = 0x05  # Low byte of address
  result[0x113] = 0x43  # High byte of address (full address: $4305 - DMASIZEL register)
  result[0x114] = 0xBD  # LDA $0403,X (Load Accumulator, direct page indexed X)
  result[0x115] = 0x03  # Low byte of address
  result[0x116] = 0x04  # High byte of address (full address: $0403)
  # TODO: Determine what memory location $0403 represents
  result[0x117] = 0x8D  # STA $4302 (Store Accumulator, absolute addressing - set DMA source)
  result[0x118] = 0x02  # Low byte of address
  result[0x119] = 0x43  # High byte of address (full address: $4302 - DMAP1 register)
  result[0x11A] = 0xBC  # LDY $0405,X (Load Y register, direct page indexed X)
  result[0x11B] = 0x05  # Low byte of address
  result[0x11C] = 0x04  # High byte of address (full address: $0405)
  # TODO: Determine what memory location $0405 represents
  result[0x11D] = 0x8C  # STY $4304 (Store Y register, absolute addressing - set DMA bank)
  result[0x11E] = 0x04  # Low byte of address
  result[0x11F] = 0x43  # High byte of address (full address: $4304 - DMAB1 register)
  
  # 0x8261-0x8270: VRAM address and loop control
  result[0x120] = 0xBD  # LDA $0406,X (Load Accumulator, direct page indexed X)
  result[0x121] = 0x06  # Low byte of address
  result[0x122] = 0x04  # High byte of address (full address: $0406)
  # TODO: Determine what memory location $0406 represents
  result[0x123] = 0x8D  # STA $2116 (Store Accumulator, absolute addressing - set VRAM address)
  result[0x124] = 0x16  # Low byte of address
  result[0x125] = 0x21  # High byte of address (full address: $2116 - VMADDL register)
  # TODO: Understand VRAM address configuration
  result[0x126] = 0x8A  # TXA (Transfer X register to Accumulator)
  result[0x127] = 0x18  # CLC (Clear Carry flag)
  result[0x128] = 0x69  # ADC #$0008 (Add with Carry, immediate mode)
  result[0x129] = 0x08  # Low byte: 0x08
  result[0x12A] = 0x00  # High byte: 0x00 (value is 0x0008)
  # TODO: Understand why 8 is added to X register
  result[0x12B] = 0xAA  # TAX (Transfer Accumulator to X register)
  result[0x12C] = 0xA0  # LDY #$01 (Load Y register, immediate mode)
  result[0x12D] = 0x01  # Immediate value: 0x01
  result[0x12E] = 0x8C  # STY $420B (Store Y register, absolute addressing - enable DMA channel 1)
  result[0x12F] = 0x0B  # Low byte of address
  result[0x130] = 0x42  # High byte of address (full address: $420B - MDMAEN register)
  
  # 0x8271-0x8280: Loop condition and branch
  result[0x131] = 0xE4  # CPX $00 (Compare X register, direct page addressing)
  result[0x132] = 0x00  # Direct page address $00
  # TODO: Determine what memory location $00 represents
  result[0x133] = 0xD0  # BNE $8241 (Branch if Not Equal, relative addressing)
  result[0x134] = 0xCA  # Relative offset: -54 bytes (branches to $8241 if not equal)
  result[0x135] = 0x86  # STX $01 (Store X register, direct page addressing)
  result[0x136] = 0x01  # Direct page address $01
  result[0x137] = 0xE2  # SEP #$20 (Set Processor status bits - set accumulator to 8-bit)
  result[0x138] = 0x20  # Immediate value: set M flag (8-bit accumulator)
  result[0x139] = 0xA5  # LDA $2C (Load Accumulator, direct page addressing)
  result[0x13A] = 0x2C  # Direct page address $2C
  # TODO: Determine what memory location $2C represents
  result[0x13B] = 0xD0  # BNE $8334 (Branch if Not Equal, relative addressing)
  result[0x13C] = 0x03  # Relative offset: +3 bytes (branches to $8334 if not equal)
  result[0x13D] = 0x4C  # JMP $8334 (Jump, absolute addressing)
  result[0x13E] = 0x34  # Low byte of address
  result[0x13F] = 0x83  # High byte of address (full address: $8334)
  
  # 0x8281-0x8290: Conditional branch and PPU register writes
  result[0x140] = 0x3A  # DEC A (Decrement Accumulator)
  result[0x141] = 0xD0  # BNE $8292 (Branch if Not Equal, relative addressing)
  result[0x142] = 0x52  # Relative offset: +82 bytes (branches to $8292 if not equal)
  result[0x143] = 0xA5  # LDA $41 (Load Accumulator, direct page addressing)
  result[0x144] = 0x41  # Direct page address $41
  # TODO: Determine what memory location $41 represents
  result[0x145] = 0x8D  # STA $210D (Store Accumulator, absolute addressing - set BG1 horizontal scroll)
  result[0x146] = 0x0D  # Low byte of address
  result[0x147] = 0x21  # High byte of address (full address: $210D - BG1HOFS register)
  # TODO: Understand background scroll configuration
  result[0x148] = 0xA5  # LDA $42 (Load Accumulator, direct page addressing)
  result[0x149] = 0x42  # Direct page address $42
  # TODO: Determine what memory location $42 represents
  result[0x14A] = 0x8D  # STA $210D (Store Accumulator, absolute addressing - set BG1 horizontal scroll high)
  result[0x14B] = 0x0D  # Low byte of address
  result[0x14C] = 0x21  # High byte of address (full address: $210D - BG1HOFS register)
  result[0x14D] = 0xA5  # LDA $45 (Load Accumulator, direct page addressing)
  result[0x14E] = 0x45  # Direct page address $45
  # TODO: Determine what memory location $45 represents
  result[0x14F] = 0x8D  # STA $210E (Store Accumulator, absolute addressing - set BG1 vertical scroll)
  result[0x150] = 0x0E  # Low byte of address
  result[0x151] = 0x21  # High byte of address (full address: $210E - BG1VOFS register)
  result[0x152] = 0xA5  # LDA $46 (Load Accumulator, direct page addressing)
  result[0x153] = 0x46  # Direct page address $46
  # TODO: Determine what memory location $46 represents
  result[0x154] = 0x8D  # STA $210E (Store Accumulator, absolute addressing - set BG1 vertical scroll high)
  result[0x155] = 0x0E  # Low byte of address
  result[0x156] = 0x21  # High byte of address (full address: $210E - BG1VOFS register)
  
  # 0x8291-0x82A0: Additional PPU register writes
  result[0x157] = 0xA5  # LDA $49 (Load Accumulator, direct page addressing)
  result[0x158] = 0x49  # Direct page address $49
  # TODO: Determine what memory location $49 represents
  result[0x159] = 0x8D  # STA $210F (Store Accumulator, absolute addressing - set BG2 horizontal scroll)
  result[0x15A] = 0x0F  # Low byte of address
  result[0x15B] = 0x21  # High byte of address (full address: $210F - BG2HOFS register)
  result[0x15C] = 0xA5  # LDA $4A (Load Accumulator, direct page addressing)
  result[0x15D] = 0x4A  # Direct page address $4A
  # TODO: Determine what memory location $4A represents
  result[0x15E] = 0x8D  # STA $210F (Store Accumulator, absolute addressing - set BG2 horizontal scroll high)
  result[0x15F] = 0x0F  # Low byte of address
  result[0x160] = 0x21  # High byte of address (full address: $210F - BG2HOFS register)
  result[0x161] = 0xA5  # LDA $4D (Load Accumulator, direct page addressing)
  result[0x162] = 0x4D  # Direct page address $4D
  # TODO: Determine what memory location $4D represents
  result[0x163] = 0x8D  # STA $2110 (Store Accumulator, absolute addressing - set BG2 vertical scroll)
  result[0x164] = 0x10  # Low byte of address
  result[0x165] = 0x21  # High byte of address (full address: $2110 - BG2VOFS register)
  result[0x166] = 0xA5  # LDA $4E (Load Accumulator, direct page addressing)
  result[0x167] = 0x4E  # Direct page address $4E
  # TODO: Determine what memory location $4E represents
  result[0x168] = 0x8D  # STA $2110 (Store Accumulator, absolute addressing - set BG2 vertical scroll high)
  result[0x169] = 0x10  # Low byte of address
  result[0x16A] = 0x21  # High byte of address (full address: $2110 - BG2VOFS register)
  
  # 0x82A1-0x82B0: More PPU register writes
  result[0x16B] = 0xA5  # LDA $51 (Load Accumulator, direct page addressing)
  result[0x16C] = 0x51  # Direct page address $51
  # TODO: Determine what memory location $51 represents
  result[0x16D] = 0x8D  # STA $2111 (Store Accumulator, absolute addressing - set BG3 horizontal scroll)
  result[0x16E] = 0x11  # Low byte of address
  result[0x16F] = 0x21  # High byte of address (full address: $2111 - BG3HOFS register)
  result[0x170] = 0xA5  # LDA $52 (Load Accumulator, direct page addressing)
  result[0x171] = 0x52  # Direct page address $52
  # TODO: Determine what memory location $52 represents
  result[0x172] = 0x8D  # STA $2111 (Store Accumulator, absolute addressing - set BG3 horizontal scroll high)
  result[0x173] = 0x11  # Low byte of address
  result[0x174] = 0x21  # High byte of address (full address: $2111 - BG3HOFS register)
  result[0x175] = 0xA5  # LDA $55 (Load Accumulator, direct page addressing)
  result[0x176] = 0x55  # Direct page address $55
  # TODO: Determine what memory location $55 represents
  result[0x177] = 0x8D  # STA $2112 (Store Accumulator, absolute addressing - set BG3 vertical scroll)
  result[0x178] = 0x12  # Low byte of address
  result[0x179] = 0x21  # High byte of address (full address: $2112 - BG3VOFS register)
  result[0x17A] = 0xA5  # LDA $56 (Load Accumulator, direct page addressing)
  result[0x17B] = 0x56  # Direct page address $56
  # TODO: Determine what memory location $56 represents
  result[0x17C] = 0x8D  # STA $2112 (Store Accumulator, absolute addressing - set BG3 vertical scroll high)
  result[0x17D] = 0x12  # Low byte of address
  result[0x17E] = 0x21  # High byte of address (full address: $2112 - BG3VOFS register)
  
  # 0x82B1-0x82C0: More PPU register writes
  result[0x17F] = 0xA5  # LDA $59 (Load Accumulator, direct page addressing)
  result[0x180] = 0x59  # Direct page address $59
  # TODO: Determine what memory location $59 represents
  result[0x181] = 0x8D  # STA $2113 (Store Accumulator, absolute addressing - set BG4 horizontal scroll)
  result[0x182] = 0x13  # Low byte of address
  result[0x183] = 0x21  # High byte of address (full address: $2113 - BG4HOFS register)
  result[0x184] = 0xA5  # LDA $5A (Load Accumulator, direct page addressing)
  result[0x185] = 0x5A  # Direct page address $5A
  # TODO: Determine what memory location $5A represents
  result[0x186] = 0x8D  # STA $2113 (Store Accumulator, absolute addressing - set BG4 horizontal scroll high)
  result[0x187] = 0x13  # Low byte of address
  result[0x188] = 0x21  # High byte of address (full address: $2113 - BG4HOFS register)
  result[0x189] = 0xA5  # LDA $5D (Load Accumulator, direct page addressing)
  result[0x18A] = 0x5D  # Direct page address $5D
  # TODO: Determine what memory location $5D represents
  result[0x18B] = 0x8D  # STA $2114 (Store Accumulator, absolute addressing - set BG4 vertical scroll)
  result[0x18C] = 0x14  # Low byte of address
  result[0x18D] = 0x21  # High byte of address (full address: $2114 - BG4VOFS register)
  result[0x18E] = 0xA5  # LDA $5E (Load Accumulator, direct page addressing)
  result[0x18F] = 0x5E  # Direct page address $5E
  # TODO: Determine what memory location $5E represents
  result[0x190] = 0x8D  # STA $2114 (Store Accumulator, absolute addressing - set BG4 vertical scroll high)
  result[0x191] = 0x14  # Low byte of address
  result[0x192] = 0x21  # High byte of address (full address: $2114 - BG4VOFS register)
  
  # 0x82C1-0x82D0: Branch and alternative PPU register writes
  result[0x193] = 0x80  # BRA $8334 (Branch Always, relative addressing)
  result[0x194] = 0x5E  # Relative offset: +94 bytes (jumps to $8334)
  result[0x195] = 0xA5  # LDA $43 (Load Accumulator, direct page addressing)
  result[0x196] = 0x43  # Direct page address $43
  # TODO: Determine what memory location $43 represents
  result[0x197] = 0x8D  # STA $210D (Store Accumulator, absolute addressing - set BG1 horizontal scroll)
  result[0x198] = 0x0D  # Low byte of address
  result[0x199] = 0x21  # High byte of address (full address: $210D - BG1HOFS register)
  result[0x19A] = 0xA5  # LDA $44 (Load Accumulator, direct page addressing)
  result[0x19B] = 0x44  # Direct page address $44
  # TODO: Determine what memory location $44 represents
  result[0x19C] = 0x8D  # STA $210D (Store Accumulator, absolute addressing - set BG1 horizontal scroll high)
  result[0x19D] = 0x0D  # Low byte of address
  result[0x19E] = 0x21  # High byte of address (full address: $210D - BG1HOFS register)
  result[0x19F] = 0xA5  # LDA $47 (Load Accumulator, direct page addressing)
  result[0x1A0] = 0x47  # Direct page address $47
  # TODO: Determine what memory location $47 represents
  result[0x1A1] = 0x8D  # STA $210E (Store Accumulator, absolute addressing - set BG1 vertical scroll)
  result[0x1A2] = 0x0E  # Low byte of address
  result[0x1A3] = 0x21  # High byte of address (full address: $210E - BG1VOFS register)
  result[0x1A4] = 0xA5  # LDA $48 (Load Accumulator, direct page addressing)
  result[0x1A5] = 0x48  # Direct page address $48
  # TODO: Determine what memory location $48 represents
  result[0x1A6] = 0x8D  # STA $210E (Store Accumulator, absolute addressing - set BG1 vertical scroll high)
  result[0x1A7] = 0x0E  # Low byte of address
  result[0x1A8] = 0x21  # High byte of address (full address: $210E - BG1VOFS register)
  
  # 0x82D1-0x82E0: More alternative PPU register writes
  result[0x1A9] = 0xA5  # LDA $4B (Load Accumulator, direct page addressing)
  result[0x1AA] = 0x4B  # Direct page address $4B
  # TODO: Determine what memory location $4B represents
  result[0x1AB] = 0x8D  # STA $210F (Store Accumulator, absolute addressing - set BG2 horizontal scroll)
  result[0x1AC] = 0x0F  # Low byte of address
  result[0x1AD] = 0x21  # High byte of address (full address: $210F - BG2HOFS register)
  result[0x1AE] = 0xA5  # LDA $4C (Load Accumulator, direct page addressing)
  result[0x1AF] = 0x4C  # Direct page address $4C
  # TODO: Determine what memory location $4C represents
  result[0x1B0] = 0x8D  # STA $210F (Store Accumulator, absolute addressing - set BG2 horizontal scroll high)
  result[0x1B1] = 0x0F  # Low byte of address
  result[0x1B2] = 0x21  # High byte of address (full address: $210F - BG2HOFS register)
  result[0x1B3] = 0xA5  # LDA $4F (Load Accumulator, direct page addressing)
  result[0x1B4] = 0x4F  # Direct page address $4F
  # TODO: Determine what memory location $4F represents
  result[0x1B5] = 0x8D  # STA $2110 (Store Accumulator, absolute addressing - set BG2 vertical scroll)
  result[0x1B6] = 0x10  # Low byte of address
  result[0x1B7] = 0x21  # High byte of address (full address: $2110 - BG2VOFS register)
  result[0x1B8] = 0xA5  # LDA $50 (Load Accumulator, direct page addressing)
  result[0x1B9] = 0x50  # Direct page address $50
  # TODO: Determine what memory location $50 represents
  result[0x1BA] = 0x8D  # STA $2110 (Store Accumulator, absolute addressing - set BG2 vertical scroll high)
  result[0x1BB] = 0x10  # Low byte of address
  result[0x1BC] = 0x21  # High byte of address (full address: $2110 - BG2VOFS register)
  
  # 0x82E1-0x82F0: More alternative PPU register writes
  result[0x1BD] = 0xA5  # LDA $53 (Load Accumulator, direct page addressing)
  result[0x1BE] = 0x53  # Direct page address $53
  # TODO: Determine what memory location $53 represents
  result[0x1BF] = 0x8D  # STA $2111 (Store Accumulator, absolute addressing - set BG3 horizontal scroll)
  result[0x1C0] = 0x11  # Low byte of address
  result[0x1C1] = 0x21  # High byte of address (full address: $2111 - BG3HOFS register)
  result[0x1C2] = 0xA5  # LDA $54 (Load Accumulator, direct page addressing)
  result[0x1C3] = 0x54  # Direct page address $54
  # TODO: Determine what memory location $54 represents
  result[0x1C4] = 0x8D  # STA $2111 (Store Accumulator, absolute addressing - set BG3 horizontal scroll high)
  result[0x1C5] = 0x11  # Low byte of address
  result[0x1C6] = 0x21  # High byte of address (full address: $2111 - BG3HOFS register)
  result[0x1C7] = 0xA5  # LDA $57 (Load Accumulator, direct page addressing)
  result[0x1C8] = 0x57  # Direct page address $57
  # TODO: Determine what memory location $57 represents
  result[0x1C9] = 0x8D  # STA $2112 (Store Accumulator, absolute addressing - set BG3 vertical scroll)
  result[0x1CA] = 0x12  # Low byte of address
  result[0x1CB] = 0x21  # High byte of address (full address: $2112 - BG3VOFS register)
  result[0x1CC] = 0xA5  # LDA $58 (Load Accumulator, direct page addressing)
  result[0x1CD] = 0x58  # Direct page address $58
  # TODO: Determine what memory location $58 represents
  result[0x1CE] = 0x8D  # STA $2112 (Store Accumulator, absolute addressing - set BG3 vertical scroll high)
  result[0x1CF] = 0x12  # Low byte of address
  result[0x1D0] = 0x21  # High byte of address (full address: $2112 - BG3VOFS register)
  
  # 0x82F1-0x8300: More alternative PPU register writes
  result[0x1D1] = 0xA5  # LDA $5B (Load Accumulator, direct page addressing)
  result[0x1D2] = 0x5B  # Direct page address $5B
  # TODO: Determine what memory location $5B represents
  result[0x1D3] = 0x8D  # STA $2113 (Store Accumulator, absolute addressing - set BG4 horizontal scroll)
  result[0x1D4] = 0x13  # Low byte of address
  result[0x1D5] = 0x21  # High byte of address (full address: $2113 - BG4HOFS register)
  result[0x1D6] = 0xA5  # LDA $5C (Load Accumulator, direct page addressing)
  result[0x1D7] = 0x5C  # Direct page address $5C
  # TODO: Determine what memory location $5C represents
  result[0x1D8] = 0x8D  # STA $2113 (Store Accumulator, absolute addressing - set BG4 horizontal scroll high)
  result[0x1D9] = 0x13  # Low byte of address
  result[0x1DA] = 0x21  # High byte of address (full address: $2113 - BG4HOFS register)
  result[0x1DB] = 0xA5  # LDA $5F (Load Accumulator, direct page addressing)
  result[0x1DC] = 0x5F  # Direct page address $5F
  # TODO: Determine what memory location $5F represents
  result[0x1DD] = 0x8D  # STA $2114 (Store Accumulator, absolute addressing - set BG4 vertical scroll)
  result[0x1DE] = 0x14  # Low byte of address
  result[0x1DF] = 0x21  # High byte of address (full address: $2114 - BG4VOFS register)
  result[0x1E0] = 0xA5  # LDA $60 (Load Accumulator, direct page addressing)
  result[0x1E1] = 0x60  # Direct page address $60
  # TODO: Determine what memory location $60 represents
  result[0x1E2] = 0x8D  # STA $2114 (Store Accumulator, absolute addressing - set BG4 vertical scroll high)
  result[0x1E3] = 0x14  # Low byte of address
  result[0x1E4] = 0x21  # High byte of address (full address: $2114 - BG4VOFS register)
  
  # 0x8301-0x8310: Memory operations and register configuration
  result[0x1E5] = 0xC2  # REP #$20 (Reset Processor status bits - set accumulator to 16-bit)
  result[0x1E6] = 0x20  # Immediate value: clear M flag (16-bit accumulator)
  result[0x1E7] = 0xAD  # LDA $0031 (Load Accumulator, absolute addressing)
  result[0x1E8] = 0x31  # Low byte of address
  result[0x1E9] = 0x00  # High byte of address (full address: $0031)
  # TODO: Determine what memory location $0031 represents
  result[0x1EA] = 0x8D  # STA $0061 (Store Accumulator, absolute addressing)
  result[0x1EB] = 0x61  # Low byte of address
  result[0x1EC] = 0x00  # High byte of address (full address: $0061)
  # TODO: Determine what memory location $0061 represents
  result[0x1ED] = 0xAD  # LDA $0033 (Load Accumulator, absolute addressing)
  result[0x1EE] = 0x33  # Low byte of address
  result[0x1EF] = 0x00  # High byte of address (full address: $0033)
  # TODO: Determine what memory location $0033 represents
  result[0x1F0] = 0x8D  # STA $0063 (Store Accumulator, absolute addressing)
  result[0x1F1] = 0x63  # Low byte of address
  result[0x1F2] = 0x00  # High byte of address (full address: $0063)
  # TODO: Determine what memory location $0063 represents
  result[0x1F3] = 0xA0  # LDY #$00 (Load Y register, immediate mode)
  result[0x1F4] = 0x00  # Immediate value: 0x00
  result[0x1F5] = 0x84  # STY $2C (Store Y register, direct page addressing)
  result[0x1F6] = 0x2C  # Direct page address $2C
  result[0x1F7] = 0xA6  # LDX $0D (Load X register, direct page addressing)
  result[0x1F8] = 0x0D  # Direct page address $0D
  result[0x1F9] = 0x30  # BMI $8340 (Branch if Minus, relative addressing)
  result[0x1FA] = 0x0F  # Relative offset: +15 bytes (branches to $8340 if negative)
  result[0x1FB] = 0xA6  # LDX $1A (Load X register, direct page addressing)
  result[0x1FC] = 0x1A  # Direct page address $1A
  # TODO: Determine what memory location $1A represents
  result[0x1FD] = 0x8E  # STX $212C (Store X register, absolute addressing - set main screen designation)
  result[0x1FE] = 0x2C  # Low byte of address
  result[0x1FF] = 0x21  # High byte of address (full address: $212C - TM register)
  # TODO: Understand main screen designation configuration

