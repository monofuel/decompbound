## Autoresearch scorecard writer (schema v0) for the llm-play eval loop.
## Contract: docs/autoresearch-llm-play.md + Softmax autoresearch
## docs/scorecard.schema.v0.md. Copyright hygiene is enforced HERE, not in
## prose: keys are allowlisted and string values must be token-shaped (no
## whitespace), so dialogue text or other game content cannot ride along.

import
  std/[json, os, strformat, strutils, times]

type
  EvalTier* = enum
    ## Top-level schema `tier` field: which eval stage produced this card.
    etScreen = "screen"
    etConfirm = "confirm"

  EvalDecision* = enum
    ## Gate outcome for this candidate run.
    edKeep = "keep"
    edDiscard = "discard"
    edInconclusive = "inconclusive"

  HardConstraint* = object
    ## One hard floor: any `pass = false` vetoes `keep`.
    name*: string
    pass*: bool
    value*: string

  Scorecard* = object
    ## One run's gate artifact, written to runs/<utc>-<idea>/scorecard.json.
    ideaId*: string
    candidateId*: string
    baselineId*: string
    utc*: string
    tier*: EvalTier
    primaryName*: string
    primaryValue*: float
    higherIsBetter*: bool
    hardConstraints*: seq[HardConstraint]
    n*: int
    seedsOrSlate*: string
    decision*: EvalDecision
    reasonCodes*: seq[string]
    links*: seq[string]
    domainExtra*: JsonNode

const
  SchemaVersion* = 0
  MaxTokenLen = 128
  ## Only these keys may appear in domain_extra. Everything else is rejected
  ## so ad-hoc fields (which tend to grow prose) cannot creep in.
  DomainExtraAllowlist* = [
    "scaffold_tier", "pilot", "tempo", "gates", "frames", "llm_calls",
    "harness_commit", "stuck_recoveries", "fixture_scores", "stalls",
    "gate_frames",
  ]

proc isTokenShaped(s: string): bool =
  ## True when a string is a safe machine token: non-empty, bounded, and free
  ## of whitespace/control characters. Dialogue and prose always contain
  ## spaces, so this mechanically blocks game text from entering a scorecard.
  if s.len == 0 or s.len > MaxTokenLen:
    return false
  for ch in s:
    if ch in {' ', '\t', '\n', '\r'} or ord(ch) < 32:
      return false
  true

proc checkTokenValues(node: JsonNode, path: string) =
  ## Recursively require every string in a JSON subtree to be token-shaped.
  case node.kind
  of JString:
    if not isTokenShaped(node.getStr()):
      raise newException(ValueError,
        fmt"scorecard value at {path} is not token-shaped (whitespace/empty/too long): rejected to keep game text out")
  of JObject:
    for k, v in node.pairs:
      if not isTokenShaped(k):
        raise newException(ValueError, fmt"scorecard key at {path}.{k} is not token-shaped")
      checkTokenValues(v, path & "." & k)
  of JArray:
    for i, v in node.elems:
      checkTokenValues(v, fmt"{path}[{i}]")
  else:
    discard

proc validate*(card: Scorecard) =
  ## Enforce schema invariants and the copyright allowlist; raises on any
  ## violation so an invalid card can never claim keep.
  for (label, s) in [("idea_id", card.ideaId), ("candidate_id", card.candidateId),
                     ("baseline_id", card.baselineId), ("utc", card.utc),
                     ("primary name", card.primaryName)]:
    if not isTokenShaped(s):
      raise newException(ValueError, fmt"scorecard {label} must be token-shaped, got '{s}'")
  if card.n < 0:
    raise newException(ValueError, "scorecard n must be >= 0")
  if card.seedsOrSlate.len > 0 and not isTokenShaped(card.seedsOrSlate):
    raise newException(ValueError, "scorecard seeds_or_slate must be token-shaped")
  for rc in card.reasonCodes:
    if not isTokenShaped(rc):
      raise newException(ValueError, fmt"reason code '{rc}' must be token-shaped")
  for link in card.links:
    if not isTokenShaped(link):
      raise newException(ValueError, fmt"link '{link}' must be token-shaped (opaque path, no content)")
  for hc in card.hardConstraints:
    if not isTokenShaped(hc.name):
      raise newException(ValueError, fmt"hard constraint name '{hc.name}' must be token-shaped")
    if hc.value.len > 0 and not isTokenShaped(hc.value):
      raise newException(ValueError, fmt"hard constraint value for {hc.name} must be token-shaped")
    if not hc.pass and card.decision == edKeep:
      raise newException(ValueError,
        fmt"hard constraint {hc.name} failed but decision is keep — schema invariant 1 violated")
  if card.domainExtra != nil:
    if card.domainExtra.kind != JObject:
      raise newException(ValueError, "domain_extra must be a JSON object")
    for k, v in card.domainExtra.pairs:
      if k notin DomainExtraAllowlist:
        raise newException(ValueError,
          fmt"domain_extra key '{k}' is not in the allowlist {DomainExtraAllowlist}")
      checkTokenValues(v, "domain_extra." & k)

proc toJson*(card: Scorecard): JsonNode =
  ## Render the scorecard to the schema-v0 JSON shape.
  var constraints = newJArray()
  for hc in card.hardConstraints:
    var c = %*{"name": hc.name, "pass": hc.pass}
    if hc.value.len > 0:
      c["value"] = %hc.value
    constraints.add(c)
  var links = newJObject()
  for i, link in card.links:
    links[fmt"link{i}"] = %link
  result = %*{
    "schema_version": SchemaVersion,
    "idea_id": card.ideaId,
    "candidate_id": card.candidateId,
    "baseline_id": card.baselineId,
    "utc": card.utc,
    "tier": $card.tier,
    "primary_for_ranking": {
      "name": card.primaryName,
      "value": card.primaryValue,
      "higher_is_better": card.higherIsBetter,
    },
    "hard_constraints": constraints,
    "n": card.n,
    "seeds_or_slate": card.seedsOrSlate,
    "decision": $card.decision,
    "reason_codes": card.reasonCodes,
    "links": links,
    "domain_extra": (if card.domainExtra != nil: card.domainExtra else: newJObject()),
  }

proc utcStamp*(): string =
  ## Filesystem-safe UTC timestamp for run directory names.
  now().utc.format("yyyyMMdd'T'HHmmss'Z'")

proc writeScorecard*(card: Scorecard, runsDir: string): string =
  ## Validate and write the card to <runsDir>/<utc>-<idea_id>/scorecard.json;
  ## returns the scorecard path. Raises (never writes) on validation failure.
  validate(card)
  let runDir = runsDir / fmt"{card.utc}-{card.ideaId}"
  createDir(runDir)
  result = runDir / "scorecard.json"
  writeFile(result, pretty(toJson(card)) & "\n")

proc summaryLine*(card: Scorecard): string =
  ## The one-line gate summary the eval contract requires on stdout.
  var floors = "pass"
  for hc in card.hardConstraints:
    if not hc.pass:
      floors = "fail"
      break
  fmt"primary={card.primaryValue:g} floors={floors} decision={card.decision}"
