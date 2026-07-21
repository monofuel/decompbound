## Regression gate for the per-frame memory leak (and its sibling, the rare frame
## stutter). Root cause: bus.write8 unconditionally appended every touched address
## to bus.dirty, which is ONLY consumed by the vector-test harness — so in normal
## emulation it grew one int per memory write forever (heap leak + periodic
## realloc-copy pause). The fix gates the append behind bus.recordDirty (default
## OFF); only run_vectors / the single-step test opt in.
##
## ROM-free and deterministic: drives bus.write8 directly, no emulator state.
## If someone removes the gate, dirty.len explodes and the heap grows — both caught.

import
  ../src/decompbound/cpu

proc main() =
  const Writes = 1_000_000

  # 1. DEFAULT path (recordDirty = false): the leak must be gone.
  block:
    let bus = newBus()
    doAssert not bus.recordDirty, "recordDirty must default OFF (leak-free path)"
    let heapBefore = getOccupiedMem()
    for i in 0 ..< Writes:
      bus.write8((i and 0xFFFF).uint32, (i and 0xFF).uint8)
    let heapGrowth = getOccupiedMem() - heapBefore
    doAssert bus.dirty.len == 0,
      "bus.dirty must stay empty when recordDirty is off (got " & $bus.dirty.len &
      ") — the write8 leak has regressed"
    # 1M writes at 8 B/int would be ~8 MB if the gate were removed; a healthy path
    # allocates essentially nothing. Generous bound to stay noise-proof under ORC.
    doAssert heapGrowth < 512 * 1024,
      "heap grew " & $(heapGrowth div 1024) & " KB over " & $Writes &
      " writes — the dirty-list leak has regressed"

  # 2. OPT-IN path (recordDirty = true): the vector harness still gets its list.
  block:
    let bus = newBus()
    bus.recordDirty = true
    for i in 0 ..< 1000:
      bus.write8((i and 0xFFFF).uint32, 0x42'u8)
    doAssert bus.dirty.len == 1000,
      "recordDirty=true must record every write for the harness (got " &
      $bus.dirty.len & ")"
    bus.dirty.setLen(0)
    doAssert bus.dirty.len == 0, "harness reset (setLen 0) must clear the list"

  echo "test_frame_leak OK"

when isMainModule:
  main()
