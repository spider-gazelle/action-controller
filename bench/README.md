# Initial performance harness

This is the first, small milestone from [the performance plan](../PERFORMANCE_PLAN.md). It provides a repeatable router lookup probe and a two-route HTTP/1.1 comparison with Action Controller, bare Crystal HTTP and Ohkami. It does not cover the full workload matrix or establish a framework-wide speed ratio.

## Requirements and builds

Use Crystal >= 1.21, Rust/Cargo, Python 3.9+ and `oha` (tested with 1.16.0). Check out Ohkami as a sibling of Action Controller at `../ohkami`; the Rust manifest deliberately uses that local source. Record its git revision. The Rust `Cargo.lock` in this directory pins downloaded packages. The Action Controller `shard.lock` is ignored by this repository, so record its content hash and the installed LuckyRouter source revision for a published run.

From the Action Controller root:

```sh
mkdir -p bench/bin
crystal build --release -o bench/bin/router bench/router.cr
crystal build --release -o bench/bin/http bench/http.cr
cargo build --release --manifest-path bench/ohkami/Cargo.toml
```

For a quick lookup probe:

```sh
bench/bin/router 1000000
bench/bin/router 1000000 dynamic-hit 1000
bench/bin/router 1000000 dynamic-hit 1000 simple
```

The probe defaults to a 201-route table. Optional arguments select one case and change the number of static/dynamic route pairs. The final `simple` argument omits the generic fallback route, allowing candidate optimizations that only support simple tail captures to be assessed separately. It reports nanoseconds and Boehm GC's cumulative allocated bytes per lookup. It reuses one HTTP context and request strings; it measures route lookup, not full request allocation. The result is a development clue and must not be added arithmetically to HTTP request times.

## HTTP comparison

```sh
python3 bench/run.py --duration 60s --warmup 15s --repeats 5 --connections 32 --output /tmp/ac-http-results.json
python3 bench/report.py /tmp/ac-http-results.json
```

To compare a candidate with an already built baseline Action Controller binary in randomized order:

```sh
python3 bench/run.py --modes baseline action-controller --baseline-binary /tmp/ac-http-before --duration 60s --warmup 15s --repeats 5 --output /tmp/ac-compare.json
python3 bench/report.py /tmp/ac-compare.json
```

The runner starts a fresh server for each measurement, validates status and body, randomizes run order, runs `oha` over HTTP/1.1 with keep-alive, and saves the complete `oha` JSON plus host/tool versions, commands, git state and response headers. The default 10-second, three-repeat setting is for development; use the longer invocation above for decisions. All three servers run with one request-processing worker. Run on an isolated Linux machine with a separate or isolated load generator for release claims. The same-host Mac run remains exploratory.

Use `--paths /json /json-buffered` to compare JSON response writing. Both paths return the same body. `/json` serializes the object directly to response IO; `/json-buffered` serializes to a String and writes once. The bare Crystal fixture uses the same two approaches. The Ohkami fixture uses its normal JSON responder for both paths. These variants expose the cost of many small writes to Crystal's HTTP response.

Both paths return HTTP 200 and the same body: `/plain` returns `OK`, `/user/abc` returns `abc`. Response headers currently differ: Ohkami adds Date and `charset=UTF-8`, while Crystal emits `Connection: keep-alive` and `text/plain`. Record this difference with the results. The bare Crystal dynamic route is intentionally simple and does not model all router semantics. Add matched header and realistic middleware profiles before interpreting small gaps. Do not use ApacheBench for this comparison: it sent HTTP/1.0 requests that this Ohkami fixture rejected.

The Ohkami fixture now uses the same LTO, single-codegen-unit and panic-abort settings as Ohkami's `benches_rt` release profile. The first exploratory result was built before this change, and the aligned-profile rerun is saved separately. Crystal's `--release` uses its own `-O3 --single-module` profile. Record both compiler profiles and target CPU settings before publication.

Check the saved JSON for failures, response-code distributions and unusually wide run variance. `oha` may report a few deadline-aborted in-flight requests from a duration run; they are distinct from server failures. The reporter rejects other failures. Sweep connection counts, offered loads and CPU budgets as described in the main plan before choosing an implementation.
