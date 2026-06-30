# Execution Contexts

Action Controller can run request handling and response serialisation in separate
[execution contexts](https://crystal-lang.org/reference/latest/guides/concurrency.html)
so that a large, CPU heavy response (typically JSON) cannot cause head-of-line
blocking of other requests sharing a scheduler thread.

This is an opt-in, experimental feature built on Crystal's
[RFC 2 execution contexts](https://github.com/crystal-lang/rfcs/pull/2). It is
**fully resolved at compile time** — the generated route code calls the chosen
context directly, there is no per-request lookup.

## Requirements

Execution contexts require both compiler flags:

```sh
crystal build -Dpreview_mt -Dexecution_context src/app.cr
```

Without these flags **every entry point below is a no-op**: contexts are not
created, configuration is ignored, and responses serialise inline. Code that
references the API still compiles unchanged, so a shard can adopt it without
forcing the flags on its users.

## Concepts

A **named execution context** is a dedicated pool of schedulers
(`Fiber::ExecutionContext::Parallel`). You `define` one, then **bind** it to a
controller or an individual route. A bound route runs its **whole request** —
filters, action, and response serialisation — in that context.

Routes that are **not** bound run on the default (request) fiber. Their response
is serialised inline unless you opt in to offloading (see
[Offloading unbound responses](#offloading-unbound-responses)).

## Defining a context

Declare your contexts once, e.g. in `config.cr`. Names are string literals.

```crystal
# parallelism is the maximum number of schedulers (defaults to 4)
ActionController::ExecutionContext.define "reports", parallelism: 2
ActionController::ExecutionContext.define "heavy-json"
```

Each context is created **once, lazily**, the first time it is used.

The size can be overridden at runtime, before the context is first used — handy
for sizing from the environment:

```crystal
ActionController::ExecutionContext.parallelism "reports", ENV["REPORT_WORKERS"]?.try(&.to_i) || 2
```

A context name referenced by a controller or route that was never `defined` is a
**compile-time error**.

## Binding to a controller

`execution_context` binds every route in the controller to a named context. The
whole request runs there.

```crystal
class Reports < ActionController::Base
  base "/reports"
  execution_context "reports"

  @[AC::Route::GET("/")]
  def index : Array(Report)
    Report.all.to_a            # runs in the "reports" context
  end
end
```

The binding is inherited by subclasses (a subclass can override it with its own
`execution_context`).

## Binding to a single route

The `execution_context` annotation argument binds one route and takes precedence
over the controller-wide binding.

```crystal
class Reports < ActionController::Base
  base "/reports"
  execution_context "reports"                                   # default for this controller

  @[AC::Route::GET("/")]
  def index : Array(Report)
    Report.all.to_a                                             # -> "reports"
  end

  @[AC::Route::GET("/export", execution_context: "heavy-json")]
  def export : Array(HugePayload)
    HugePayload.all.to_a                                        # -> "heavy-json"
  end
end
```

**Resolution precedence (compile time):** route annotation → controller default →
unbound.

## Offloading unbound responses

By default a route with **no** bound context serialises its response inline on the
request fiber — cheapest for small responses (no fiber spawn, no channel).

If your unbound routes can also return large payloads, opt in to offloading their
serialisation to a shared `response_context`:

```crystal
# config.cr — off by default, compile-time switch
ActionController::ExecutionContext.offload_responses

# size of the shared response context (defaults to 4)
ActionController::ExecutionContext.response_parallelism = 8
```

With this enabled, an unbound route runs its action on the request fiber and then
serialises the response body in the shared `response_context`. Bound routes are
unaffected — they always run the whole request in their own context.

## Behaviour details

- **HEAD requests** have no body to serialise. A bound route still runs the whole
  request (including HEAD) in its context, but the `offload_responses` offload for
  unbound routes is skipped for HEAD requests (there is nothing to offload).
- **WebSocket routes** are never offloaded — they are long-lived and would
  otherwise occupy a context fiber for the whole connection.
- **Errors** raised in a bound request propagate back to the request fiber with
  their backtrace intact. An exception handler (`@[AC::Route::Exception]`) in a
  bound controller serialises its response inline on the bound context — no extra
  hop.
- **OpenAPI** generation is unaffected; the `execution_context` annotation
  argument does not appear in the generated documents.

## Configuration reference

| Entry point | Kind | Default | Purpose |
|---|---|---|---|
| `ExecutionContext.define "name", parallelism: n` | macro | `n` = 4 | declare a named context |
| `ExecutionContext.parallelism "name", n` | runtime | — | override a context's size before first use |
| `execution_context "name"` | controller macro | — | bind every route in the controller |
| `@[AC::Route::VERB("/p", execution_context: "name")]` | annotation | — | bind a single route (overrides the controller) |
| `ExecutionContext.offload_responses` | macro | off | offload unbound responses to `response_context` |
| `ExecutionContext.response_parallelism = n` | runtime | 4 | size of the shared response context |

All of the above are no-ops without `-Dpreview_mt -Dexecution_context`.
