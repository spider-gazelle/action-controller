# Action Controller performance plan

Implementation has begun on branch `perf/benchmark-baseline`. The first release-build fixtures, repeatable runner and exploratory measurements are in [`bench/`](bench/README.md), with the initial result in [`bench/BASELINE.md`](bench/BASELINE.md). Stage A remains open until the isolated Linux runs, profiling and broader workloads are complete.

## Objective and evidence

Aim for a substantial reduction in CPU time and allocations per request, with no application changes and no observable changes to existing routing, controller, middleware, or response behavior. Treat the reported ~2× Ohkami throughput advantage as a hypothesis to reproduce, not an established measurement for every workload. This document is a source review and implementation plan; no comparative benchmarks were run for it.

Reviewed on 2026-09-23:

- Action Controller `08c65c4a0eaab9e51b7f12c795d0a4ebd5c16e6d` (shard version 8.1.2; Crystal >= 1.21.0).
- Ohkami `7845dfcf7cdee6ec96a8d9136057e16caa0eb0cc` in the adjacent checkout.
- Installed LuckyRouter sources and `shard.lock`, which records 0.6.1. Archive/hash the installed sources as part of benchmarking: a lockfile alone does not prove a local dependency is unmodified.

Set an initial stretch target of 1.5–2× baseline throughput on framework-bound workloads at the same CPU budget, while maintaining latency and correctness. This is a target, not a prediction. Publish results per workload; do not conceal regressions behind an average. Define representative application traffic and latency budgets before choosing a winner.

**Recommendation:** establish the cost breakdown first, optimize common request work, then trial a byte-oriented router behind the existing interface. Do not begin by committing to a LuckyRouter replacement. Exact static routes already bypass it.

## What the current code tells us

| Area | Source evidence | Implication / experiment |
| --- | --- | --- |
| Static routing | [`RouteHandler`](src/action-controller/router/route_handler.cr) checks a `{method, path}` hash before LuckyRouter and stores trailing-slash aliases. Registration still calls LuckyRouter for validation. | Replacing the dynamic matcher cannot speed up a static hash hit. Compare this path against bare HTTP before redesigning it. The tuple lookup optimization already exists. |
| Dynamic routing | Installed `lib/lucky_router/src/lucky_router/matcher.cr` uses a 16-element `StaticArray` with an array fallback. `path_reader.cr` constructs segment strings and decodes percent escapes; `fragment.cr` traverses hashes/arrays recursively, creates a successful-match hash, and inserts captures while unwinding. | Measure segmentation, decoding, traversal, and capture materialization separately. Avoid proposing the existing small-array optimization as new work. |
| Controller dispatch | [`base.cr`](src/action-controller/base.cr), `__draw_routes__`, generates route methods, instantiates a controller per request, and specializes filters at compile time. [`builder.cr`](src/action-controller/router/builder.cr) generates conversion/response wrappers. | Measure generated code and allocations. There is no general runtime filter registry to eliminate. Preserve controller construction and subclass initialization semantics. |
| Parameters | `Base.extract_params` copies query values into `URI::Params` and merges route values. `params` then parses form data. Required path arguments already read `route_params` directly. | Query/form/optional arguments are stronger candidates than another required-path shortcut. Profile repeated-key handling and copying; preserve merge order, mutation isolation, and body consumption. |
| Negotiation | [`responders.cr`](src/action-controller/responders.cr) already scans Accept manually; `can_respond_with?` already avoids array intersection. The scanner still builds an array and token strings. | Try an internal scanner that selects a responder without materializing all tokens, especially for absent/common Accept headers. Keep the public array-returning API and overrides working. |
| Response writing | Generated responders already write JSON to response IO; explicit render also writes directly. Sessions/cookies and combined params are lazy. | Do not “optimize” by introducing a JSON string buffer or implementing laziness that already exists. Profile serialization, response headers, and HTTP buffering independently. |
| Scheduling | [`execution_context.cr`](src/action-controller/execution_context.cr) defaults to inline serialization. Opt-in offloading creates a channel and spawns a fiber; named contexts can run a whole request. | Keep tiny responses inline. Evaluate heavy-response isolation using mixed-load tail latency, not just isolated JSON throughput. |
| Middleware / HTTP | [`server.cr`](src/action-controller/server.cr) wraps Crystal `HTTP::Server` with configured before/router/after handlers. [`LogHandler`](src/action-controller/log_handler.cr) adds log context and timing; request IDs are generated when request-event logging is enabled. | Attribute HTTP parsing/writing, logging and framework overhead separately. A bare-server gap requires runtime/stdlib investigation, not router work. |

Ohkami's local `ohkami/src/router/final.rs` uses method-specific trees, compressed static byte patterns and indexed captures in `request/path.rs`. These suggest avoiding segment allocations and precomputing route structure. They are not a drop-in specification: this checkout has a two-capture inline storage limit, different HEAD handling, and different matching/decoding behavior. Action Controller must retain arbitrary supported parameter counts and its own semantics.

## Benchmark design

### Reproducible harness

Add a versioned `bench/` suite to this repository with equivalent Action Controller and Ohkami applications, a bare Crystal HTTP application, request corpora, a runner, response validators and machine-readable results. Pin dependency revisions and load-generator versions. Retain commands, environment, raw histograms and profiling artifacts with each report.

Record CPU model/topology, OS/kernel, memory, compiler/LLVM/Rust versions, dependency source hashes, build flags, runtime features, worker/process counts, CPU affinity, logging configuration, HTTP settings and payload sizes. Build Crystal with `--release` and Rust with `--release`; record any CPU targeting or LTO separately. Ohkami's `benches_rt/Cargo.toml` already enables LTO, one codegen unit and panic-abort. Do not compare a development build with that profile.

Use two explicit comparisons:

1. One CPU core and one request-processing worker for cost per request. Explicitly configure Ohkami's runtime: its Tokio sample uses `#[tokio::main]`, so do not assume it is a single-worker baseline.
2. Equal total CPU budgets at 2, 4 and 8 cores where available, counting all processes, scheduler threads and offload pools. Test process clustering and execution contexts separately. Label each Ohkami runtime; do not combine results from Tokio and other runtimes into one baseline.

Start with HTTP/1.1, keep-alive, no TLS, no compression and no pipelining. Match status, content type, body bytes, header workload and application work. Validate framing and record chunked versus Content-Length behavior; do not silently attribute a different wire workload to routing. Add TLS, connection churn and streaming as separate experiments. Run both frameworks minimally configured, then with equivalent realistic middleware. Never disable existing behavior in only the optimized variant.

Use a dedicated Linux host for release decisions, with generator cores isolated from server cores or a separate generator machine. macOS is useful for development checks. Verify that client CPU/network are not the bottleneck. Keep frequency/power settings and background load stable.

Warm each process for at least 15 seconds; measure for 60 seconds, repeating at least five times in randomized baseline/candidate order. Restart between independent runs and run a longer soak after selecting candidates. Extend runs if variance or GC cycles make results unstable. Sweep concurrency (1, 8, 32, 128, 512, subject to host capacity) rather than reporting one favorable point.

Use a closed-loop generator for capacity sweeps and a fixed-arrival-rate generator with scheduled-request latency accounting for latency-under-load tests. Record offered load, achieved load, missed arrivals, timeouts and errors; a saturated closed-loop client hides queuing delay. Test shared absolute rates around 25%, 50%, 75% and 90% of baseline sustainable capacity, then determine each candidate's maximum throughput within the same latency/error budget.

Report successful requests/s, p50/p95/p99 latency, CPU-seconds per successful request, RSS/peak memory, allocation bytes/count where instrumentation supports them, GC collections/time, errors and response validation failures. Use medians and uncertainty intervals across runs. CPU/allocation profiling runs are separate from uninstrumented performance measurements.

### Workload matrix

| Workload | Variants / purpose |
| --- | --- |
| Static plaintext | One route and large route tables; tiny constant body. Establish HTTP plus minimal controller overhead. |
| JSON | Equivalent serialization of a small object, 4 KB and 100 KB bodies; separate prebuilt bytes from object serialization. |
| Dynamic paths | 1, 2, 5 and 20 captures; shallow/deep paths, common prefixes, broad sibling sets, encoded/unencoded values. |
| Route-table scale | 10, 100, 1,000 and 10,000 routes; static/dynamic mix; hot-route skew and uniform selection. Measure startup, compilation and binary size too. |
| Misses / fallbacks | Unknown path, wrong method, static branch failure followed by dynamic/glob fallback; after-handlers and final 404. |
| Parameters / bodies | Query scalars, repeated keys, optional path values, conflicting query/path/form keys, JSON POST, URL-encoded form and multipart uploads. |
| Features | Explicit render versus annotated return; before/around/after filters; session untouched/read/modified; logging off/on; errors and rejected Accept. |
| Scheduling | Tiny requests mixed with large JSON and CPU-heavy handlers; inline, named context, shared response offload and cluster variants. |
| Lifecycle | HEAD, redirects, streaming and WebSocket upgrades as correctness and targeted performance cases. |

Do not force Ohkami to support incompatible routes just to fill the table. Use the common feature subset for cross-framework comparisons and the full matrix for baseline-versus-candidate Action Controller regressions.

### Locate the bottleneck

Measure four levels with the same payloads:

1. Pure matcher: preconstructed route tables, varied prebuilt request paths, successful matches and misses; consume payload/capture results so work cannot be eliminated.
2. In-process `RouteHandler` and controller execution using fresh request/response contexts; no socket. Include context construction consistently and report an isolated matching benchmark separately.
3. Bare Crystal `HTTP::Server` over a socket with equivalent headers and body work.
4. Full Action Controller and equivalent Ohkami over sockets, then realistic application middleware.

Use CPU sampling (Linux perf/flamegraphs, or Instruments on macOS), GC statistics and available allocation instrumentation to establish attribution. Do not infer allocation counts solely from RSS. Inspect macro-expanded code/assembly only for measured hot spots.

Use Amdahl's law to prioritize: if matching is 15% of request CPU, making it infinitely fast yields at most `1 / 0.85 = 1.18×`; making it twice as fast yields about `1.08×`. A 2× overall gain requires eliminating roughly half the original cost. Compare bare Crystal and Action Controller to estimate framework headroom, but use profiles rather than subtracting saturated throughput figures as if they were additive timings.

## Optimization sequence

### 1. Reduce common request work

Start with small independent patches, each backed by a measured allocation/CPU reduction:

- Add an internal allocation-light Accept selection path, preserving ordering, wildcard handling, unsupported-type behavior and custom responders. Do not change quality-value semantics as part of performance work. Avoid caching across mutable request headers unless invalidation is correct.
- Reduce unnecessary copying in combined parameter extraction, especially repeated keys. Keep `params`, `query_params`, `route_params`, form fields and their mutation/precedence behavior intact. Do not skip form parsing based only on a typed argument's apparent source.
- Specialize response dispatch where metadata proves a fixed responder, retaining custom transforms, existing Content-Type overrides, status mapping, nil returns, HEAD and explicit rendering. Check what is already specialized before adding branches/macros.
- Profile log-context/timing overhead when logging is disabled. Any fast path must preserve enabled event behavior, redaction, error logging and downstream log context. Do not remove logging from the default application to claim a gain.

Keep one controller instance per request. Pooling controllers, request contexts or mutable parameter hashes risks leaked state and retained references across concurrent requests; it is not an initial strategy. Likewise, preserve session write timing and upload cleanup rather than deleting apparently redundant calls without lifecycle tests.

### 2. Trial a faster dynamic router

Evaluate three candidates against the current implementation: a targeted LuckyRouter improvement suitable for upstreaming; an internal byte-oriented radix/segment tree; and generated dispatch for a small/simple route set. Generated dispatch is an experiment, not a requirement: large generated decision trees can inflate compile time, binary size and instruction-cache pressure.

Retain `RouteHandler#add_route`, `#search_route`, `#call`, `#process_request`, the Action tuple, and the static hash fast path initially. Preserve telemetry injection through `process_request`. Choose a backend once during setup (prefer specialization where useful), not by adding a new per-request configuration lookup.

Proposed internal matcher:

- Precompute route structure, method dispatch, capture names and optional-route expansions during registration.
- Match path bytes/offsets without allocating every segment. Keep an owned path reference for any offsets; never retain pointers into reusable HTTP buffers.
- Store captures in bounded inline storage with a general overflow path; support more than 16 segments and arbitrary currently supported capture counts.
- Backtrack correctly from a failed static branch to dynamic/glob alternatives, restoring capture state. Preserve route registration precedence.
- Decode segments in accordance with current behavior. An encoded static segment can match a decoded route; `%2F` inside a segment must not become a separator through whole-path decoding. Use a compatible slow path for percent escapes initially.
- First materialize the existing `Hash(String, String)` at the match boundary. This preserves the context API while isolating gains from traversal. Only then consider lazy capture materialization as a separate patch.

Lazy parameters are a higher-risk follow-up: the public `route_params` getter/setter exposes a mutable Hash, and filters or middleware may mutate/replace it before generated arguments read it. An internal indexed accessor must observe those changes and preserve hash identity, enumeration order and lifetime. If that cannot be proven, retain eager hashes. Never share a mutable empty hash across requests.

Keep LuckyRouter as the default during development and retain an explicit rollback selection during rollout. Differential testing runs both matchers against the same corpus and compares results, without executing actions twice. Optional production shadowing must be sampled and compare matches only; its overhead must be excluded from published benchmarks.

Do not remove the dependency until exception types, direct requires, transitive dependency users and extension hooks have been audited. A new internal default with the old dependency retained can deliver the gain without forcing a breaking removal.

### 3. Address serialization and transport if profiles justify it

If bare Crystal remains near Action Controller and substantially below Ohkami, prioritize HTTP parsing, header allocation, response buffering, write syscalls, connection handling and GC in Crystal's stdlib/runtime. Prefer upstream improvements compatible with `HTTP::Server`. Compare buffer strategies across tiny and streaming/large responses; full buffering must not become the universal default.

Treat a different HTTP engine as a separate, opt-in architectural project. Action Controller exposes concrete `HTTP::Server::Context`, response IO, handlers and `server.socket`; replacing those transparently is a much larger compatibility problem than replacing the router. Do not bypass HTTP parsing or framing validation to improve a microbenchmark.

Use execution contexts for measured CPU-heavy isolation and throughput improvements. Preserve current inline defaults and configuration behavior. Crystal's [parallelism guide](https://crystal-lang.org/reference/1.21/guides/parallelism.html) describes the context types; test the exact supported compiler/flags rather than assuming scheduling behavior is unchanged between releases.

## Compatibility gate

Freeze observable behavior from the current implementation before optimization. Existing specs are necessary but not enough. Add characterization and differential tests covering:

- Static/dynamic/glob precedence, alternate branches after a partial match, insertion order, root/empty paths, trailing and repeated slashes, optional static and dynamic segments, named/unnamed globs, duplicate/invalid registration and error classes/messages.
- Encoded literals/captures, encoded slash and percent, plus, Unicode, malformed escapes and invalid byte sequences; long paths and overflow capture storage. Record baseline quirks rather than silently “correcting” them.
- All methods, method case, explicit HEAD versus automatic GET-to-HEAD registration in both orders, body suppression and headers, unsupported methods, misses and after-handler invocation. Do not copy Ohkami's HEAD policy.
- Parameter type converters/defaults/unions, missing versus invalid values, query/path/form precedence, repeated keys, direct Hash mutation/replacement, body reads and upload cleanup.
- Filter inheritance/order/skip behavior, early rendering, around-filter unwind, exception handlers, sessions/cookies, redirects, custom serializers, Accept selection, status mapping, streaming and WebSocket upgrades.
- Public DSL/annotations, route helpers/listing and OpenAPI output, direct Router registration, telemetry hooks, custom controller initialization and middleware integration.
- Concurrent requests across supported runtime modes, ensuring no shared capture state or cross-request data leakage; disconnection and exception paths.

Use seeded generated route tables and paths, shrinking mismatches to fixtures. Compare payload identity, captures including order where observable, errors and full HTTP behavior. The oracle must be Action Controller's complete static-plus-LuckyRouter path, not LuckyRouter alone: the wrapper has its own aliases and precedence. Include registration failures and fallback behavior, not just successful requests. Upstream [LuckyRouter documentation](https://github.com/luckyframework/lucky_router) is useful context; the pinned source and measured baseline remain the compatibility authority.

## Delivery and decision gates

| Stage | Deliverable | Exit criterion |
| --- | --- | --- |
| A: Baseline | Reproducible harness, original ~2× comparison configuration if recoverable, profiles and cost breakdown | Validated responses, stable repeated results, equal resource budgets; unexplained differences recorded. |
| B: Compatibility | Characterization corpus and differential runner | Current backend passes; key behavior and extension contracts documented. |
| C: Common-path changes | Separate negotiation/parameter/dispatch patches selected by profiles | Correctness suite passes and repeatable end-to-end benefit exceeds noise. |
| D: Router experiment | LuckyRouter improvement and/or alternate backend with benchmark report | Full parity; material dynamic-route gain; static routes and misses remain healthy. |
| E: Runtime work | Serialization/HTTP/upstream patches only where attribution supports them | Improved realistic workloads, bounded memory and preserved streaming behavior. |
| F: Rollout | Opt-in release, downstream app testing, canary and rollback instructions, then default switch | Sustained benefit and zero unexplained semantic differences across the supported matrix. |

As an initial promotion rule, require at least 10% end-to-end improvement in the target workload to justify a substantial router replacement, with no repeatable >3% regression in core throughput or p99 at the same offered load. Calibrate these thresholds to the measured noise floor before experiments; require unchanged correctness regardless of speed. Reject increased error rates, unbounded retained memory or compile-time/binary-size growth that outweighs the benefit. Smaller low-risk patches can be worthwhile below 10% if gains are statistically distinguishable.

Run the existing full Crystal spec and CI build matrix for implementation patches, plus new compatibility tests, on the minimum supported compiler and the chosen current release. Add performance regression jobs on a stable dedicated runner; noisy shared CI should validate benchmark correctness, not enforce small throughput thresholds. Publish baseline/candidate/Ohkami results with raw artifacts and explanations for every material regression.

The first implementation milestone is the harness and cost breakdown. Its result decides whether the next major investment is routing, controller overhead, or Crystal's HTTP/runtime layer. No claimed speedup should precede that evidence.
