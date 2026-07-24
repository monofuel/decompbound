import std/strformat
import ../decompbound/baserom_extract
proc main() =
  var n = 0
  var tot = 0
  var maxL = 0
  var maxName = ""
  for s in allBaseromExtractSpans():
    n += 1
    tot += s.length
    if s.length > maxL:
      maxL = s.length
      maxName = s.name
  echo &"spans={n} total={tot} max={maxL} ({maxName})"
  # wave104
  var w = 0
  var wb = 0
  for s in allBaseromExtractSpans():
    if "w104" in s.name or "wave104" in s.name:
      w += 1
      wb += s.length
  echo &"wave104* spans={w} bytes={wb}"
main()
