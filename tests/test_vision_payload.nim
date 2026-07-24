## Unit tests for vision_payload — real encode path, no live azem required.
import
  std/[json, strutils, os],
  pixie,
  ../src/tools/vision_payload

proc main() =
  ## Build a non-empty PNG base64 from a synthetic frame and multimodal messages.
  let img = newImage(256, 224)
  img.fill(rgbx(40, 80, 120, 255))
  # Draw a simple marker so the PNG is not a flat single-color degenerate.
  for y in 100 .. 120:
    for x in 100 .. 140:
      img[x, y] = rgbx(255, 200, 0, 255)

  let b64 = encodeFramePngBase64(img)
  doAssert b64.len > 200, "expected non-trivial PNG base64, got len=" & $b64.len
  let stats = visionPayloadStats(b64)
  doAssert "png_b64_chars=" in stats
  doAssert "image_parts=1" in stats

  let parts = userContentWithImage("RICH STATE: test scene", b64)
  doAssert parts.kind == JArray
  doAssert parts.len == 2
  doAssert parts[0]["type"].getStr == "text"
  doAssert parts[1]["type"].getStr == "image_url"
  let url = parts[1]["image_url"]["url"].getStr
  doAssert url.startsWith("data:image/png;base64,")
  doAssert url.len > b64.len

  let msgs = chatMessagesWithOptionalVision("system here", "user text", b64)
  doAssert countImageParts(msgs) == 1
  let textOnly = chatMessagesWithOptionalVision("system here", "user text", "")
  doAssert countImageParts(textOnly) == 0

  echo "OK test_vision_payload: ", stats, " messages_image_parts=", countImageParts(msgs)

when isMainModule:
  main()
