import
  decompbound/cpu

const
  Addresses = [0x002100'u32, 0x008000, 0x400000, 0x7E0024, 0x7F0000, 0xC08000]
  StoredValue = 0x12'u8
  HookValue = 0x34'u8

block hookOverridesAndFallback:
  let bus = newBus()
  for address in Addresses:
    bus.mem[address] = StoredValue
  var reads, writes: seq[uint32]
  bus.readHook = proc(address: uint32): int =
    ## Override reads across every representative bank.
    reads.add(address)
    HookValue.int
  bus.writeHook = proc(address: uint32, value: uint8): bool =
    ## Observe and handle writes without changing flat memory.
    writes.add(address)
    doAssert value == HookValue
    true
  for address in Addresses:
    doAssert bus.read8(address) == HookValue
    bus.write8(address, HookValue)
    doAssert bus.mem[address] == StoredValue
  doAssert reads == @Addresses
  doAssert writes == @Addresses
  bus.readHook = proc(address: uint32): int =
    ## Allow flat-memory reads.
    -1
  bus.writeHook = proc(address: uint32, value: uint8): bool =
    ## Allow flat-memory writes.
    false
  bus.recordDirty = true
  for address in Addresses:
    doAssert bus.read8(address) == StoredValue
    bus.write8(address, HookValue)
    doAssert bus.mem[address] == HookValue
  doAssert bus.dirty.len == Addresses.len
