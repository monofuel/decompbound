# Decomp progress (Build × Comprehension)

Axes per `docs/terms.md`. Counts are **claimed region bytes** from
`manifest.json` — not coincidental matches against gold.

ROM size: **3145728** bytes.

## By Build

| Level | Bytes | % of ROM |
|---|---:|---:|
| `copy` | 3143702 | 99.936% |
| `reproduce` | 2026 | 0.064% |
| `modify` | 0 | 0.000% |

## By Comprehension

| Level | Bytes | % of ROM |
|---|---:|---:|
| `unknown` | 3143702 | 99.936% |
| `identified` | 0 | 0.000% |
| `explained` | 2026 | 0.064% |

## Matrix cells

| Build | Comprehension | Bytes | Regions |
|---|---|---:|---:|
| `copy` | `unknown` | 3143702 | 18 |
| `reproduce` | `explained` | 2026 | 36 |

## Headline

- **explained** (comprehension): 2026 bytes (0.0644%)
- **reproduce** (build): 2026 bytes (0.0644%)
- **copy/unknown residual** remains the bulk of the map until more RE.
