# Composable applications

Development branch: `codex/composable-applications`. Preserve incremental commits and normal pushes; squash merge only after implementation approval.

## Approved design

Application bases select their controller subtree and act as HTTP handlers. Route misses continue to the next handler; matched actions keep their response. Existing automatic discovery and template startup remain compatible.

One composition registry supplies HTTP routing, route listing, OpenAPI, MCP and spec helpers. Definitions have controller/action identity independent of public paths. Placements support repeated and nested replacement-base mounts, without mutating requests or original definitions.

## Delivery

- [ ] Prove abstract application bases can implement HTTP::Handler as class objects, with independent `.handler` instances.
- [ ] Refactor route metadata to preserve independent controller definitions.
- [ ] Add controller subtree handlers and explicit server composition configuration.
- [ ] Add replacement-base mounting, cycles/conflict validation and placement-aware URL helpers.
- [ ] Generate unified OpenAPI and global MCP catalogs, prompts and relocated endpoints from placements.
- [ ] Scope and validate MCP descriptions against compositions.
- [ ] Verify unchanged template and composed fixtures; document the public APIs.

## Acceptance checks

- Existing suite and unchanged template compile/CLI behavior.
- Downstream fallback, action-generated 404s and filter isolation.
- Overlapping local routes, equivalent public route conflicts and implicit HEAD.
- Nested/repeated/parameterized mounts, redirects and WebSockets.
- OpenAPI public paths, operation IDs and schema references.
- MCP tools, prompts, instructions, endpoint metadata and cached descriptions.

## Review

Implementation in progress. The first checkpoint is the Crystal handler compile spike; no release or merge is authorized by this tracking document.
