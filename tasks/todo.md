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
- OpenAPI public paths, operation IDs and schema references.
- MCP tools, prompts, instructions, endpoint metadata and cached descriptions.

## Review

Follow-up review: all six GitHub checks passed on `2732359`. Eight regression examples now cover explicit parameter overrides, typed action/filter parameter relocation, optional/glob path helpers, optional endpoint session binding, inherited MCP endpoints, SpecHelper composition discovery, and atomic rejection of manually registered or already-mounted endpoint conflicts. Required target parameters cannot become optional, and URL helpers reject optional arguments that would bind to a different segment. These review fixes preserve existing APIs.

Routing, mounting, inherited metadata, OpenAPI and MCP integration are implemented. Validation after review fixes: 251 examples pass with randomized order; 254 pass with preview_mt and execution_context. All source/spec files pass the formatter. Ameba reports 237 existing findings, with none on added lines. The unchanged template builds, its seven specs pass, and its routes/docs/MCP CLI options work with a local shard override; no template source files were modified. A separate compiled fixture verifies composition selection before config initialization. README documents the APIs and compatibility behavior. The PR remains a draft pending review and CI. No release or merge is authorized by this tracking document.
