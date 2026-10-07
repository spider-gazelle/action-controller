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

Routing, mounting, inherited metadata, OpenAPI and MCP integration are implemented. Validation: 243 examples pass with randomized order; 246 pass with preview_mt and execution_context. New source/spec files pass Ameba, and all source/spec files pass the formatter. The unchanged template builds, its seven specs pass, and its routes/docs/MCP CLI options work with a local shard override; no template source files were modified. A separate compiled fixture verifies composition selection before config initialization. README documents the APIs and compatibility behavior. Repository-wide Ameba reports pre-existing findings; added lines are checked separately. The PR remains a draft pending review and CI. No release or merge is authorized by this tracking document.
