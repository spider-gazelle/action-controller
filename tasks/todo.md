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

## Acceptance checks

- Existing suite and unchanged template compile/CLI behavior.
- Downstream fallback, action-generated 404s and filter isolation.
- Overlapping local routes, equivalent public route conflicts and implicit HEAD.
- Nested/repeated/parameterized mounts, redirects and WebSockets.
- Complete subtree mounts, independent selection and namespaced forward references.
- OpenAPI public paths, operation IDs and schema references.
- MCP tools, prompts, instructions, endpoint metadata and cached descriptions.

## Review

Follow-up review: all six GitHub checks passed on `2732359`. Eight regression examples now cover explicit parameter overrides, typed action/filter parameter relocation, optional/glob path helpers, optional endpoint session binding, inherited MCP endpoints, SpecHelper composition discovery, and atomic rejection of manually registered or already-mounted endpoint conflicts. Required target parameters cannot become optional, and URL helpers reject optional arguments that would bind to a different segment. These review fixes preserve existing APIs.

Subtree review: all six GitHub checks passed on `1fdc5a3`. Four additional regression examples verify independent selection, complete app mounts, unified standalone/mounted catalogs, and an app's own descendant mounts. Exclusions now depend on the selected app's declarations; unrelated mounts cannot truncate explicit or mounted subtrees. Mount targets resolve in the declaring controller's namespace at type completion, retaining forward-reference support. The compiled startup fixture also verifies independent HTTP and catalog definitions for apps with identical original URLs.

Parameter review: all six GitHub checks passed on `d07be9b`. Four additional regression examples cover required action/filter arguments promoted into optional mount segments, declared optional source parameters moved back to queries, and MCP listings for sessions with and without URL bindings. Optional endpoint arguments remain available unless actually bound; bound session values retain precedence when invoking actions. Session-specific schema filtering does not mutate shared descriptions. Catalog identities include a version to invalidate descriptions generated with older projection behavior.

Required-segment review: all six GitHub checks passed on `aedfce0`. A further regression verifies that replacing an optional source segment with a mandatory mount segment makes MCP prompt arguments required, matching HTTP and tool behavior. Endpoint-bound arguments remain excluded, and missing prompt arguments receive the explicit MCP parameter error.

Inheritance review: all six GitHub checks passed on `c014981`. Five regression examples verify child MCP defaults for inherited actions, method annotation/icon precedence, changed and disabled inherited endpoints, consistent defaults for newly declared actions, inherited/overridden instructions, and annotated overload metadata. Declared and inherited route metadata share one configuration resolver. The nearest annotated controller supplies defaults; method annotations override them. A child that first enables an endpoint can reuse an inherited ordinary instructions method, while overriding routed instructions reuses the existing wrapper.

Context review: all six GitHub checks passed on `9b6ae81`. Six regression examples verify direct controller specs at repeated/parameterized mounts, existing spec calls using the configured default, upstream path parameter isolation, context preservation on misses, and compatibility for ordinary routers. `spec_instance` accepts an optional composition and matches that controller's placements without executing actions or filters. Explicit compositions and relocated placements reset static-route path bindings lazily, without mutating upstream hashes; automatic unmounted routing retains its existing behavior. Handler clones retain the isolation mode.

Routing, mounting, inherited metadata, OpenAPI and MCP integration are implemented. Validation after context review fixes: 271 examples pass with randomized order; 274 pass with preview_mt and execution_context. All source/spec files pass the formatter. Ameba reports 237 existing findings, with none on added lines. The unchanged template builds, its seven specs pass, and its routes/docs/MCP CLI options work with a local shard override; no template source files were modified. A separate compiled fixture verifies composition selection before config initialization. README documents the APIs and compatibility behavior. The PR remains a draft pending review and CI. No release or merge is authorized by this tracking document.
