# Composable applications

Development branch: `codex/composable-applications`. Preserve incremental commits and normal pushes; squash merge only after implementation approval.

## Approved design

Application bases select their controller subtree and act as HTTP handlers. Route misses continue to the next handler; matched actions keep their response. Existing automatic discovery and template startup remain compatible.

One composition registry supplies HTTP routing, route listing, OpenAPI, MCP and spec helpers. Definitions have controller/action identity independent of public paths. Placements support repeated and nested replacement-base mounts, without mutating requests or original definitions.

## Delivery

- [x] Prove handler construction: Crystal rejects class objects extending HTTP::Handler; independent `.handler` instances support abstract application bases.
- [x] Refactor route metadata to preserve independent controller definitions.
- [x] Add controller subtree handlers and explicit server composition configuration.
- [x] Add replacement-base mounting, cycles/conflict validation and placement-aware URL helpers.
- [x] Generate unified OpenAPI and global MCP catalogs, prompts and relocated endpoints from placements.
- [x] Scope and validate MCP descriptions against compositions.
- [x] Verify unchanged template and composed fixtures; document the public APIs.
- [x] Remove avoidable HTTP binding, URL helper allocation and warmed MCP-cache overhead.
- [x] Record release benchmark comparisons against master, including mounted dispatch and MCP listings.
- [x] Compare Proc, callable-object and generated integer dispatch with varied route working sets.
- [x] Prototype dynamic matching without copying static path segments; compare lookup and full dispatch.
- [x] Implement the fastest compatible option, verify matching/handler/catalog behavior and update PR evidence.

## Acceptance checks

- Existing suite and unchanged template compile/CLI behavior.
- Downstream fallback, action-generated 404s and filter isolation.
- Overlapping local routes, equivalent public route conflicts and implicit HEAD.
- Nested/repeated/parameterized mounts, redirects and WebSockets.
- Complete subtree mounts, independent selection and namespaced forward references.
- OpenAPI public paths, operation IDs and schema references.
- MCP tools, prompts, instructions, endpoint metadata and cached descriptions.

## Review

Router review: measured plain/captured Procs, callable objects and generated integer dispatch with 16 and 256 targets. Procs win mixed-target dispatch; one-hot alternatives save less than a nanosecond and do not justify changing the runtime action API. The implemented lazy matcher reuses LuckyRouter's trie and validation, compares temporary byte views with static String keys, and copies only successful captures. Escaped paths retain the original decoder. Local lookup measurements improve common unescaped dynamic cases by 10–16%, globs by about 46%, and reduce misses to zero allocated bytes. Actual warmed single/mounted requests save 32–64 bytes with ordinary parameters; nested dispatch improves by a few percent, with other timings around the baseline. Static routing and Proc dispatch remain unchanged. Differential specs cover branch/method failures, optional/glob routes, escaping, Unicode, empty segments, 80 captures and generated paths. Validation: 274 normal examples, 277 MT/execution-context examples and all seven unchanged-template specs pass; template routes/OpenAPI/MCP CLI generation works. Formatter/whitespace checks pass. Ameba reports 233 existing findings, none in changed router, spec or benchmark files. All six CI checks passed on `f400c28`; the router follow-up requires fresh CI. Results and reproduction commands are in `benchmarks/README.md`. Final review and approval remain outstanding.

Warmed-handler follow-up: the actual application `.handler` and a declaratively mounted app were compared with equivalent original routers at identical public paths. The fixture has 19 GET routes plus implicit HEAD, typed filters, static/dynamic/nested parameters and mounted base access. Four alternating release runs per build, with 20,000 warm-up requests and 15 samples per case, show no measurable dispatch regression across eight cases. Single-handler medians range from −1.80% to +0.07%; mounted medians are 0.95–1.65% faster. Allocation counter differences are under 0.1 byte/request. `Composition.call` now retains method/path locally, matching the original router's request reads. Details and reproduction commands are in `benchmarks/README.md`. All six CI checks passed on `47a38be`; the follow-up requires fresh CI. The full 272-example suite and 275-example MT/execution-context suite pass after the change. Final PR review and approval remain outstanding.

Performance review: release benchmarks against master (`0ef242e`) cover static/dynamic lookup and dispatch, misses, class URL helpers, warmed MCP descriptions and listings. An additional comparison covers relocated placements versus equivalent native routes. HTTP and MCP allocations are unchanged; class URL helpers allocate less. Dispatch timings show no consistent regression in this fixture, but static lookup adds an isolation check (4.5 to 4.7 ns locally), mounted dispatch stores its base, and explicit handler chains necessarily perform lookups on misses. See `benchmarks/README.md` for reproducible commands, measured ranges and limits; a literal zero-runtime-cost claim is not justified. Ordinary routes and prompts retain direct dispatch procs; public-base binding runs only for relocated routes. MCP uses immutable per-composition snapshots published atomically, avoiding warmed lookup locks and catalog hashing while preserving invalidation. A regression test covers description replacement, nil invalidation and switching files. Validation: 272 normal examples and 275 with preview_mt/execution_context pass. Ameba reports 233 existing findings with none on added lines; the unchanged template builds, its seven specs pass and routes/docs/MCP CLI checks pass. Earlier six green CI checks applied to `4879cdc`; performance changes require fresh CI and final review before approval and squash merge.

Follow-up review: all six GitHub checks passed on `2732359`. Eight regression examples now cover explicit parameter overrides, typed action/filter parameter relocation, optional/glob path helpers, optional endpoint session binding, inherited MCP endpoints, SpecHelper composition discovery, and atomic rejection of manually registered or already-mounted endpoint conflicts. Required target parameters cannot become optional, and URL helpers reject optional arguments that would bind to a different segment. These review fixes preserve existing APIs.

Subtree review: all six GitHub checks passed on `1fdc5a3`. Four additional regression examples verify independent selection, complete app mounts, unified standalone/mounted catalogs, and an app's own descendant mounts. Exclusions now depend on the selected app's declarations; unrelated mounts cannot truncate explicit or mounted subtrees. Mount targets resolve in the declaring controller's namespace at type completion, retaining forward-reference support. The compiled startup fixture also verifies independent HTTP and catalog definitions for apps with identical original URLs.

Parameter review: all six GitHub checks passed on `d07be9b`. Four additional regression examples cover required action/filter arguments promoted into optional mount segments, declared optional source parameters moved back to queries, and MCP listings for sessions with and without URL bindings. Optional endpoint arguments remain available unless actually bound; bound session values retain precedence when invoking actions. Session-specific schema filtering does not mutate shared descriptions. Catalog identities include a version to invalidate descriptions generated with older projection behavior.

Required-segment review: all six GitHub checks passed on `aedfce0`. A further regression verifies that replacing an optional source segment with a mandatory mount segment makes MCP prompt arguments required, matching HTTP and tool behavior. Endpoint-bound arguments remain excluded, and missing prompt arguments receive the explicit MCP parameter error.

Inheritance review: all six GitHub checks passed on `c014981`. Five regression examples verify child MCP defaults for inherited actions, method annotation/icon precedence, changed and disabled inherited endpoints, consistent defaults for newly declared actions, inherited/overridden instructions, and annotated overload metadata. Declared and inherited route metadata share one configuration resolver. The nearest annotated controller supplies defaults; method annotations override them. A child that first enables an endpoint can reuse an inherited ordinary instructions method, while overriding routed instructions reuses the existing wrapper.

Context review: all six GitHub checks passed on `9b6ae81`. Six regression examples verify direct controller specs at repeated/parameterized mounts, existing spec calls using the configured default, upstream path parameter isolation, context preservation on misses, and compatibility for ordinary routers. `spec_instance` accepts an optional composition and matches that controller's placements without executing actions or filters. Explicit compositions and relocated placements reset static-route path bindings lazily, without mutating upstream hashes; automatic unmounted routing retains its existing behavior. Handler clones retain the isolation mode.

Routing, mounting, inherited metadata, OpenAPI and MCP integration are implemented. Validation after context review fixes: 271 examples pass with randomized order; 274 pass with preview_mt and execution_context. All source/spec files pass the formatter. Ameba reports 237 existing findings, with none on added lines. The unchanged template builds, its seven specs pass, and its routes/docs/MCP CLI options work with a local shard override; no template source files were modified. A separate compiled fixture verifies composition selection before config initialization. README documents the APIs and compatibility behavior. The PR remains a draft pending review and CI. No release or merge is authorized by this tracking document.
