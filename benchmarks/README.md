# Composition performance

Build the same harness in both checkouts with Crystal's release optimizer. Copy
`composition.cr` into the baseline checkout's `benchmarks/` directory first.

```sh
# Baseline: master at 0ef242e
crystal build --release benchmarks/composition.cr -o /tmp/ac-bench-master

# Composition branch; also compare native and relocated placements
crystal build --release -Dcomposable_benchmark benchmarks/composition.cr -o /tmp/ac-bench-composition

# Run sequentially, with no builds or specs running concurrently
/tmp/ac-bench-master
/tmp/ac-bench-composition
/tmp/ac-bench-composition
/tmp/ac-bench-master
```

The harness warms every case, then reports the median of nine samples and
allocated bytes per operation from `GC.stats.total_bytes`. Compilation, route
registration, catalog generation and first lookups are outside the timed loops.
HTTP dispatch creates a fresh request and context, reusing the response buffer
like Crystal's HTTP server does on keep-alive connections. It runs the controller,
parameter conversion and response rendering, without network I/O. MCP listings
include the same four tools in both builds, with both toolboxes open.

## Local results, 2026-10-08

Crystal 1.21.0, Apple M4 Pro, release builds, normal single-threaded application
execution. Ranges show the two sequential runs above; they are observed medians,
not confidence intervals.

| Operation | Master ns/op | Composition ns/op | Master → composition bytes/op |
| --- | ---: | ---: | ---: |
| Static route lookup | 4.5 | 4.7 | 0 → 0 |
| Dynamic route lookup | 98.5–102.3 | 96.1–96.8 | 240 → 240 |
| Route miss | 33.6–33.8 | 33.5–34.5 | 32 → 32 |
| Static HTTP dispatch | 317.1–325.4 | 317.1–322.0 | 928 → 928 |
| Dynamic HTTP dispatch | 380.5–388.9 | 388.9–394.6 | 1184 → 1184 |
| Static URL helper | 57.1–57.3 | 3.7–3.8 | 224 → 0 |
| Dynamic URL helper | 189.0–189.3 | 145.3–148.5 | 720 → 672 |
| Warmed MCP description | 2.0 | 1.7 | 0 → 0 |
| MCP tools/list | 2436.4–2449.6 | 2395.3–2440.7 | 11744 → 11744 |

Within the composition binary, native versus mounted static dispatch measured
296.9–305.2 versus 297.6–304.7 ns/op; dynamic dispatch measured 377.1–382.4 versus
373.2–378.7 ns/op. Both pairs allocated the same bytes per request.

These results show unchanged HTTP/MCP allocations and no consistent dispatch
regression in this fixture. They do not prove a universal zero runtime cost.
Static lookups check an isolation flag; mounted dispatch stores the public base
in the context; warmed MCP snapshots perform atomic reads and validate their
generation and description path. Explicit handler chains add a lookup on every
miss. Larger route tables, parameterized mounts, session-specific schemas,
WebSockets, URL generation within mounted actions, concurrent MCP requests and
network throughput need workload-specific measurements before stronger claims.
