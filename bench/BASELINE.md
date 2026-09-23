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

## Trial: simple tail-capture shortcut

A temporary `RouteHandler` fast path for routes such as `/users/:id` was built in release mode and compared against the preceding commit. With 2,000 routes and no complex fallback, lookup fell from 155.8 to 94.3 ns/op, and allocation from 288 to 256 bytes/op. On the full two-route HTTP fixture, two randomized three-second runs showed median `/user/abc` throughput of 158,857 requests/s on baseline versus 161,899 on the candidate (about 1.9%). The `/plain` median was 164,170 versus 163,101 requests/s. These are too short to establish a small production gain.

The shortcut was removed before commit. It had to disable itself for an entire method when an optional, glob or more complex dynamic pattern was registered, and it still allocated a prefix string, capture string and parameter hash. It offered a narrow improvement with behavior risk around route precedence and encoding. The isolated speedup supports a general allocation-light matcher experiment, but the end-to-end result does not justify this particular branch of production routing code. The benchmark runner now accepts `--baseline-binary` so later candidates can use the same randomized comparison.

## Aligned Ohkami release profile

The initial Ohkami fixture used ordinary Cargo `--release`, while Ohkami's `benches_rt` profile enables LTO, one codegen unit and panic-abort. The fixture now uses those settings. A separate two-repeat, five-second local run is saved as [raw JSON](results/2026-09-23-macos-ohkami-lto.json). The run uses the same routes, connections, warmup, machine and validation as the first exploratory run.

| Path | Action Controller median req/s | Bare Crystal median req/s | Ohkami median req/s | AC p99 ms | Bare p99 ms | Ohkami p99 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `/plain` | 169,047 | 172,478 | 182,298 | 0.405 | 0.397 | 0.225 |
| `/user/abc` | 166,963 | 171,967 | 181,318 | 0.418 | 0.402 | 0.226 |

LTO did not materially change the local result: Action Controller remained close to bare Crystal HTTP, and Ohkami was roughly 8–9% ahead on these two tiny responses. The same-host, short-run limitations still apply. This does not explain a 2× result from a different workload or runtime configuration; reproducing that setup is the next priority.
