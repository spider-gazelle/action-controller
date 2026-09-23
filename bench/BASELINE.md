# Initial baseline, 2026-09-23

This is an exploratory local run, not a release benchmark or a reproduction of the reported ~2× Ohkami result. Raw per-run `oha` JSON is in [results/2026-09-23-macos-exploratory.json](results/2026-09-23-macos-exploratory.json). The committed copy only redacts the local hostname and replaces absolute workspace paths in server commands. Full unredacted output was saved locally at `/tmp/ac-http-exploratory.json` during the run.

Machine: Apple M4 Pro, macOS 27.0, Crystal 1.21.0, rustc 1.95.0, `oha` 1.16.0. Action Controller `08c65c4a0eaab9e51b7f12c795d0a4ebd5c16e6d` plus this benchmark fixture; Ohkami `7845dfcf7cdee6ec96a8d9136057e16caa0eb0cc`. Action Controller used `crystal build --release`; Ohkami used Cargo's ordinary `--release` for this standalone fixture. Both ran one request-processing worker. Client and server shared the machine. Runs used HTTP/1.1 keep-alive, 32 concurrent connections, 2 seconds warmup and 5 seconds measured time, twice per case, in randomized order. All measured responses were HTTP 200 with the expected body; `oha` reported only its normal deadline-aborted in-flight requests (28–32 per run). Response headers were not identical; see [README.md](README.md).

| Path | Action Controller median req/s | Bare Crystal median req/s | Ohkami median req/s | AC p99 ms | Bare p99 ms | Ohkami p99 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `/plain` | 166,150 | 169,519 | 181,315 | 0.427 | 0.409 | 0.231 |
| `/user/abc` | 163,789 | 168,821 | 181,984 | 0.435 | 0.418 | 0.228 |

The two Action Controller runs varied from 160,708 to 171,592 requests/s for `/plain` and 159,858 to 167,721 for `/user/abc`. This variation exceeds the tiny Action Controller versus bare Crystal difference. The figures suggest that the HTTP/socket layer deserves immediate profiling; they do not establish that router work has little value on dynamic-heavy, larger route tables. These samples are too short, too few and too exposed to shared-host load for a performance threshold.

The separate release-build lookup probe (`bench/bin/router 1000000`) measured 12.1 ns and 0 allocated bytes for a static hit, 157.9 ns and 288 bytes for a dynamic hit, 179.4 ns and 320 bytes for a dynamic fallback, and 97.7 ns and 128 bytes for a miss. It used 201 registered routes, prebuilt path strings and a reused HTTP context. These are single-run measurements and include the current route wrapper, not just LuckyRouter.

Next: run 5+ repeats of 60-second measurements on isolated Linux CPUs, add matched header/middleware and larger route-table workloads, and take CPU/allocation profiles of Action Controller and bare Crystal HTTP. Only then choose a first production optimization. The current fixture is a stable starting point for those experiments.

## Follow-up: route scale and local sampling

The lookup probe now supports a variable route-table size and a selected case. In one million dynamic-hit lookups it still allocated 288 bytes per call with 87, 201, 2,001 or 20,001 registered routes. Single-run timings ranged from 119 to 185 ns/op and did not vary monotonically with table size, so they are not a valid scaling conclusion. The stable allocation count is a useful target for a router prototype.

A five-second macOS `sample` of a long dynamic lookup run showed LuckyRouter's recursive `find_match`, `match_for_method`, GC allocation and collection in active stacks. A separate sample of HTTP traffic showed response flushing/socket waits as prominent wall-time stacks. `sample` includes blocked time and these reports do **not** provide CPU percentage attribution. No production router or transport change is justified from them alone.

The new [`router_compatibility_spec.cr`](../spec/router_compatibility_spec.cr) records static precedence, dynamic fallback, percent-decoded captures and static segments, optional captures, globs, more than sixteen captures, method separation and GET-derived HEAD. This is the first part of the compatibility gate before a router replacement.
