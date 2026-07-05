## Tiny static-file server for the docs/ folder, using Mummy — so the HTML docs
## (with their diagrams) are easy to browse locally.
##   nim r src/tools/serve.nim [port]     # default 8080
## Then open http://localhost:8080/  (Ctrl+C to stop).

import
  std/[os, strutils, nativesockets],
  mummy

const DocsDir = "docs"

proc contentType(ext: string): string =
  ## Minimal ext -> MIME map (inline so the handler stays gcsafe).
  case ext.toLowerAscii
  of ".html", ".htm": "text/html; charset=utf-8"
  of ".css": "text/css; charset=utf-8"
  of ".js": "application/javascript"
  of ".svg": "image/svg+xml"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".json": "application/json"
  of ".md", ".txt", ".nim", ".log", ".cfg", ".lock": "text/plain; charset=utf-8"
  else: "application/octet-stream"

proc handler(request: Request) {.gcsafe.} =
  ## Serve a file from docs/, defaulting "/" to index.html. Rejects traversal.
  if request.httpMethod != "GET":
    request.respond(405, body = "method not allowed")
    return
  var rel = request.path
  if rel == "/" or rel.len == 0:
    rel = "index.html"
  rel = rel.strip(chars = {'/'})
  if rel.len == 0 or ".." in rel:
    request.respond(400, body = "bad path")
    return
  let full = DocsDir / rel
  if not fileExists(full):
    request.respond(404, body = "404: /" & rel & " not found")
    return
  var headers: HttpHeaders
  headers["Content-Type"] = contentType(full.splitFile.ext)
  request.respond(200, headers, readFile(full))

when isMainModule:
  let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 8080
  let server = newServer(handler)
  echo "serving ", DocsDir, "/ at http://localhost:", port, "  (Ctrl+C to stop)"
  server.serve(Port(port))
