# Performance Benchmarks

> **Note**: shell-json is a pure Bash library using file-backed AST storage. It is designed for **small configuration files and scripting convenience**, not high-throughput data processing. These benchmarks quantify the performance characteristics.

## Test Environment

| Metric | Value |
|--------|-------|
| Bash | 5.3.15(1)-release |
| jq | jq-1.8.2 |
| Kernel | Linux |
| Storage | SSD |

## Benchmark Data

Three test files at different scales, generated with `jq`:

| File | Size | Structure |
|------|------|-----------|
| `small.json` | 2 KB | 20 books in nested object (store.book[]) |
| `medium.json` | 33 KB | 200 flat objects with nested metadata |
| `large.json` | 115 KB | 500 nested objects with sub-objects |

## Results: Parse + Dump (Roundtrip)

Minimum wall-clock time across 3 runs (lower is better):

```
Operation                  shell-json      jq          Ratio
─────────────────────────────────────────────────────────────
small.json parse+dump      2.1 s           0.002 s     ~1000x
medium.json parse+dump    63.7 s           0.003 s     ~21000x
large.json parse+dump      >120 s (TO)     0.005 s     >>24000x
```

(TO = timed out at 120 seconds)

## Analysis

### Why shell-json is slow

The file-backed AST design is the primary bottleneck:

1. **Per-node file I/O**: Every JSON value (string, number, object, array) is stored as a separate file in `/tmp/shell-json.XXXXXX/nodes/`. For a 2 KB JSON with ~100 nodes, this means ~100 file reads + ~100 file writes during parsing, plus the same during serialization.

2. **Subshell overhead**: Every `json.parse`, `json.dump`, and `json.query` invocation spawns a subshell (`$()`), which forks the Bash process. For small operations, fork overhead dominates.

3. **No caching**: Each `json.dump` call re-reads every AST node from disk. There's no in-memory cache.

4. **Text-based storage**: Node files use `printf '%q'` escaping for values, requiring encoding/decoding on every read/write.

### When to use shell-json vs jq

| Scenario | shell-json | jq |
|----------|-----------|-----|
| Tiny JSON (< 1 KB, < 50 nodes) | Acceptable (~1-2s) | Instant |
| Medium JSON (1-100 KB) | Slow (> 1 min) | Instant |
| Large JSON (> 100 KB) | Impractical | Instant |
| Quick scripting in Bash | Natural fit | Requires separate tool |
| JSONPath queries | Supported | jq syntax required |
| No external deps | Pure Bash | Requires jq binary |

### Breakdown by operation (small.json, 2 KB)

| Operation | shell-json | jq | Notes |
|-----------|-----------|-----|-------|
| Parse + dump | 2.1 s | 0.002 s | Full roundtrip |
| Key query (`$.store.book[0].title`) | ~0.3 s | < 0.001 s | Single path lookup |
| Wildcard query (`$.store.book[*].title`) | ~0.5 s | < 0.001 s | Iterates over array |
| Recursive query (`$..author`) | < 0.1 s | < 0.001 s | Subtree traversal |

## Optimization Roadmap

### Short-term (low effort, high impact)

1. **Lazy file I/O** — Cache `_AST_DIR` reads across calls within the same process. Currently every `_ast_file` call reads the PID file. A single process variable check avoids this.

2. **Batch counter reads** — `ast_next_id()` reads the counter file per call. Batching (read once, write only when batch full) reduces file I/O by ~90% for large JSONs.

3. **Tempfs guarantee** — Document that `/tmp` is expected to be tmpfs (memory-backed). On Linux this is the default. If `/tmp` is on disk, performance degrades further.

### Medium-term

4. **Sharded AST storage** — Group node files into subdirectories (e.g., `nodes/00/`, `nodes/01/`) to avoid directory scan overhead on large dirs.

5. **Bulk dump with single file read** — Store the complete JSON dump in a single file during parse, making `json.dump` a single file read instead of N reads.

6. **Optional in-memory mode** — For processes that fit in the same shell session, store `_AST_DIR` as a Bash associative array instead of files. Trade-off: memory for speed.

### Long-term

7. **Native jq-style parser** — Rewrite the parser in C and compile as a Bash loadable builtin (`enable -f`). This would give near-native performance while maintaining Bash integration.

## Self-Benchmark

Run the benchmark suite locally:

```bash
bash benchmarks/benchmark.sh 3
```

Requires `jq` installed. Reports min/mean wall-clock time across 3 iterations for each operation.
