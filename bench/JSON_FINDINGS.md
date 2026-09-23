# JSON response finding

The small JSON workload (`{"message":"Hello, world!"}`) exposes a much larger gap than plaintext on this Mac. The paths and validation are defined in [README.md](README.md). The raw `oha` results are [direct JSON](results/2026-09-23-json-direct.json) and [String-buffered JSON](results/2026-09-23-json-string.json). Each result has two randomized five-second measurements with two seconds of warmup and 32 keep-alive connections on the Apple M4 Pro host. All measured responses were HTTP 200 with the expected body. These short same-host runs are exploratory.

| JSON path | Action Controller median req/s | Bare Crystal median req/s | Ohkami median req/s |
| --- | ---: | ---: | ---: |
| Direct object serialization to response IO | 104,348 | 103,561 | 181,200 |
| Serialize to String, then write once | 154,009 | 161,412 | 182,373 |

Action Controller and bare Crystal are nearly equal in the direct case. Buffering the tiny response once improves both sharply, which identifies response IO write granularity as a likely cause of the observed JSON gap. The String approach can retain a full large response in memory, so it is a measurement reference rather than the planned production default. The next experiment is a bounded buffer that switches to direct writes after a small threshold, with tests for exact output and exception behavior.

## Bounded JSON response change

The default Action Controller JSON serializer now buffers up to 4 KiB, then sends subsequent writes directly to the response. It applies to standard `NamedTuple`, `Hash` and `Array` values. Application-defined serializers still receive the original response IO, preserving overloads specialized for `HTTP::Server::Response`. Explicit `render json:` and `respond_with` use the same helper for those standard container values. A flush from a serializer is honored, and buffered bytes are flushed if serialization raises.

The final release-build comparison against the pre-change Action Controller binary is [saved as raw JSON](results/2026-09-23-json-bounded-final.json): three randomized five-second pairs, 2 seconds warmup, 32 keep-alive connections, 100% expected responses. Median `/json` throughput rose from **103,311 to 160,208 requests/s** (about **55%**). Median p99 moved from 0.472 to 0.457 ms. A separate two-repeat, three-second smoke comparison of `/plain` and `/user/abc` found no clear non-JSON regression; those runs are too short to prove a small difference.

The `bench/json_buffer.cr` in-process probe checks output bytes and allocation for 32-byte, 4 KiB and 100 KiB string fields. With 100 KiB, direct and bounded serialization took about 112.5 and 112.9 µs/op respectively in a single local run; bounded writing allocated about 336 additional bytes per operation. That probe writes to `IO::Memory`, not a socket, and is not a large-response latency claim. The helper has tests for exact small/large output, flush after an exception, and both explicit and generated custom response-specialized serializers. An isolated Linux run with large JSON and realistic middleware remains a release gate.

## Large HTTP response check

The matched `/json-large` fixture returns a preallocated 100,000-character string field. [Raw results](results/2026-09-23-json-large.json) contain three randomized five-second runs per server, two seconds of warmup, 32 keep-alive connections, and only expected HTTP 200 responses. Median throughput was 12,155 req/s for Action Controller, 12,312 for bare Crystal HTTP, and 24,893 for Ohkami; median p99 was 5.334, 5.382, and 1.561 ms, respectively. This is a short, same-host Mac comparison, not an isolated capacity result. It shows no material Action Controller overhead beyond bare Crystal for this payload, while the Crystal-vs-Ohkami gap persists. The diagnostic paths below narrow the likely cause before further framework changes.

## Separating encoding and writing

The [paired dynamic and pre-serialized HTTP runs](results/2026-09-23-json-large-static.json) use the same 100 KiB body. Median dynamic/pre-serialized throughput was 12,002/50,464 req/s for Action Controller, 11,780/50,455 for bare Crystal, and 24,260/64,466 for Ohkami. These results show that work done while serializing the body accounts for most of the gap. The pre-serialized path also narrows the Crystal-to-Ohkami ratio from roughly 2× to 1.28×, though headers and runtime behavior still differ.

A fresh serialized String per request is another reference point. Before the render fix below, [its three-run comparison](results/2026-09-23-json-large-buffered.json) measured 6,349 req/s for Action Controller, 10,746 for bare Crystal, and 24,321 for Ohkami. Investigation found that explicit `render json: expression` evaluated the expression twice: once for the macro's return value and again to write the body. Reusing the first value preserves the return value and yields one evaluation. A [paired before/after run](results/2026-09-23-json-render-once.json) raised this path from 6,219 to 10,882 req/s (about 75%). A regression spec verifies a side-effecting expression runs once and produces the expected body. The unbounded String path remains diagnostic, not the default response strategy.

We also tried draining and reusing the 4 KiB bounded buffer after it filled. A [paired run](results/2026-09-23-json-chunks.json) measured 12,043 versus 12,023 req/s for the large response and 159,206 versus 160,147 for small JSON. The differences were within this short-run noise, so that change was reverted. The next useful step is a CPU/allocation profile of Crystal JSON encoding and response writes, followed by an isolated Linux comparison; do not infer a router bottleneck from this payload.
