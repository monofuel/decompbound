# Probes (RE digs / experiments)

One-off scripts for reverse-engineering and LLM-play investigation.

- **Product tools** live in `../tools/` — keep that tree clean.
- **New digs go here** (`probe_*.nim`, fixture `synth_*.nim`).
- Run: `nim r src/probes/probe_<name>.nim`
- Imports: `../decompbound/[…]` and `../tools/[…]`.

See root `AGENTS.md` → Tools vs probes.
