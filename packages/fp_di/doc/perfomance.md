# Performance

## 2026-11-17 — fp_di 0.2.1

Apple M3 Pro · 36 GiB RAM · macOS 26.6.2 · Dart 3.13.7 · JIT · 5 runs.
Source: `16b5746786e24077bcf8564181cf6a73534e9909`.

| Workload | Operation | Median (ms) | Min–max (ms) |
|---|---|---|---|
| 2,000 members, random dependency order | Initialize | 83 | 82–97 |
| 2,000 members, random dependency order | Dispose | 53 | 53–60 |
| 4,000 members, chain | Initialize | 47 | 47–51 |
| 4,000 members, two predecessors | Initialize | 39 | 37–42 |
| 4,000 members, star | Initialize | 26 | 24–28 |
| 32,000 members, chain | Initialize | 201 | 197–216 |
| 32,000 members, chain | Dispose | 140 | 127–164 |
| 4,000-member chain, state read at every transition | Initialize | 334 | 321–337 |
| 1,000 set contributors, 20 strict readers, declaration order | Initialize | 61 | 58–67 |
| 1,000 set contributors, 20 strict readers, reverse order | Initialize | 50 | 48–55 |
