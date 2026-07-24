## Pure vision helpers for LLM-play: frame buffer → PNG base64 → OpenAI-style
## multimodal user content parts. Kept free of HTTP / azem so unit tests and
## probes can prove a non-empty image part without a live model.
##
## See docs/grok_play_work.md Stream A. Latency is high on local qwen (~tens of
## seconds); callers should gate with --vision and fire sparsely.

import
  std/[base64, json, strformat],
  pixie

proc encodeFramePngBase64*(img: Image): string =
  ## Encode a rendered frame as a PNG data URL payload (base64 only, no prefix).
  ## Empty image is rejected — never send a zero-length vision part.
  if img.isNil or img.width <= 0 or img.height <= 0:
    raise newException(ValueError, "encodeFramePngBase64: empty frame")
  let png = img.encodeImage(PngFormat)
  if png.len == 0:
    raise newException(ValueError, "encodeFramePngBase64: PNG encode produced 0 bytes")
  encode(png)

proc dataUrlPng*(b64: string): string =
  ## Full data URL for OpenAI-compatible image_url parts.
  if b64.len == 0:
    raise newException(ValueError, "dataUrlPng: empty base64")
  "data:image/png;base64," & b64

proc userContentWithImage*(textPrompt, pngB64: string): JsonNode =
  ## Build the multimodal `content` array for a user message: text + image_url.
  ## Both parts are required when vision is enabled.
  if textPrompt.len == 0:
    raise newException(ValueError, "userContentWithImage: empty text prompt")
  if pngB64.len == 0:
    raise newException(ValueError, "userContentWithImage: empty png base64")
  result = newJArray()
  result.add(%* {
    "type": "text",
    "text": textPrompt
  })
  result.add(%* {
    "type": "image_url",
    "image_url": {
      "url": dataUrlPng(pngB64)
    }
  })

proc visionPayloadStats*(pngB64: string): string =
  ## One-line stats for probes/logs (no image bytes dumped).
  let urlLen = if pngB64.len > 0: dataUrlPng(pngB64).len else: 0
  let parts = if pngB64.len > 0: 1 else: 0
  fmt"png_b64_chars={pngB64.len} data_url_chars={urlLen} image_parts={parts}"

proc chatMessagesWithOptionalVision*(
    systemPrompt, userText, pngB64: string
): JsonNode =
  ## Full `messages` array: system text + user (text-only or multimodal).
  result = newJArray()
  result.add(%* {"role": "system", "content": systemPrompt})
  if pngB64.len > 0:
    result.add(%* {
      "role": "user",
      "content": userContentWithImage(userText, pngB64)
    })
  else:
    result.add(%* {"role": "user", "content": userText})

proc countImageParts*(messages: JsonNode): int =
  ## Count image_url content parts in a messages array (for tests/probes).
  result = 0
  if messages.kind != JArray: return
  for msg in messages:
    if not msg.hasKey("content"): continue
    let c = msg["content"]
    if c.kind == JArray:
      for part in c:
        if part.hasKey("type") and part["type"].getStr == "image_url":
          inc result
