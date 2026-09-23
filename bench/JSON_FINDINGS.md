# JSON response finding

The small JSON workload (`{"message":"Hello, world!"}`) exposes a much larger gap than plaintext on this Mac. The paths and validation are defined in [README.md](README.md). The raw `oha` results are [direct JSON](results/2026-09-23-json-direct.json) and [String-buffered JSON](results/2026-09-23-json-string.json). Each result has two randomized five-second measurements with two seconds of warmup and 32 keep-alive connections on the Apple M4 Pro host. All measured responses were HTTP 200 with the expected body. These short same-host runs are exploratory.

| JSON path | Action Controller median req/s | Bare Crystal median req/s | Ohkami median req/s |
| --- | ---: | ---: | ---: |
| Direct object serialization to response IO | 104,348 | 103,561 | 181,200 |
| Serialize to String, then write once | 154,009 | 161,412 | 182,373 |

Action Controller and bare Crystal are nearly equal in the direct case. Buffering the tiny response once improves both sharply, which identifies response IO write granularity as a likely cause of the observed JSON gap. The String approach can retain a full large response in memory, so it is a measurement reference rather than the planned production default. The next experiment is a bounded buffer that switches to direct writes after a small threshold, with tests for exact output and exception behavior.
