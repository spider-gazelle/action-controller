# Spider-Gazelle Action Controller

[![CI](https://github.com/spider-gazelle/action-controller/actions/workflows/ci.yml/badge.svg)](https://github.com/spider-gazelle/action-controller/actions/workflows/ci.yml)

Extending [lucky_router](https://github.com/luckyframework/lucky_router) for a Rails like DSL without the overhead. See the [docs site](https://spider-gazelle.net/) for usage details

## Composable applications

Every controller class provides `.handler`, which returns a fresh `HTTP::Handler` serving that class and its concrete descendants. It also works on an abstract application base such as the template's `App::Base`:

```crystal
HTTP::Server.new([
  App::Base.handler,
  OtherAC::App::Base.handler,
  HTTP::StaticFileHandler.new("www", directory_listing: false),
])
```

A route miss calls the next handler. A matched action keeps its response, including a deliberate 404 or an authentication failure. Application filters run only when one of that application's routes matches. Use a fresh handler for each server or chain; request controllers still take an `HTTP::Server::Context` in their constructor.

Explicit compositions and apps with mounts isolate matched routes from path parameters set by upstream handlers. Route misses preserve the context for the next handler. Ordinary automatic routing retains its existing path parameter behavior.

For one server with unified route listing, OpenAPI and MCP, select application roots in `config.cr`, after requiring their controllers:

```crystal
ActionController::Server.compose(App::Base, OtherAC::App::Base)
```

This is a compile-time declaration, so it also applies to the template's `--routes`, `--docs` and `--mcp` options, which execute before configuration initialization. Declare it once. Existing `Server.new`, `Server.before`, `Server.after`, OpenAPI and MCP calls work unchanged. Without a declaration, controllers are discovered automatically as before. Reusable apps should expose their controllers in a library entry point; require their executable startup and global configuration only when running them standalone.

### Mounting controllers and apps

```crystal
class MyApp < AC::Base
  base "/myapp/"
  mount "/auth/", OtherAC::App::OAuth2
end
```

The mount replaces the target's base. If `OAuth2` has `base "/oauth2"` and a `/token` action, the public URL is `/myapp/auth/token`. Targets can use names relative to the declaring controller's namespace and can be declared later. A mounted application base includes its descendants, preserving their paths relative to that base. For example, an app with `base "/api"` and a descendant controller with `base "/api/users"` mounted at `/service` exposes that controller at `/service/users`. Controller bases outside the app base retain their whole path beneath the mount. `base` continues to set each controller's own path; it does not implicitly prefix descendants.

Mounts can be nested or repeated. Mount-only targets are excluded from standalone automatic discovery. Explicitly selecting an application includes its descendants independently of mounts declared in other applications; its own mount declarations determine which descendants are relocated. Mounting a whole application likewise includes its complete subtree. Mounted controllers keep their own filters and exception handlers. Parent controllers' filters apply to their own actions. Requests retain their public path, and unmatched mounted routes continue downstream.

Parameterized mounts such as `mount "/accounts/:account_id/auth", OAuth2` bind those parameters for controller filters and actions, OpenAPI and MCP. Mounts must preserve any required parameters from the target's original routes as required parameters. Cycles, ambiguous parameter names and conflicting public operations are rejected. Explicit composition also checks equivalent parameterized routes and generated HEAD operations. MCP endpoint conflicts are checked against the actual router before endpoints are registered.

Optional mount segments retain the action's argument requirements. If a query argument becomes an optional path segment, OpenAPI describes its query form on URLs that omit the segment; required action and filter arguments stay required in MCP. Replacing a base that contains an optional parameter moves declared arguments back to queries. If the replacement makes that segment mandatory, tools and prompts require its value. MCP endpoint listings omit only arguments bound by the current session URL, so sessions without an optional segment can still supply that argument.

Use `route_path(:action, ...)` inside an action to generate a URL using the current mounted base and bound path parameters:

```crystal
redirect_to route_path(:token)
```

Explicit URL arguments override bound path values. Helpers encode individual path segments and support optional (`?:`) and glob (`*:`) segments; later optional segments require earlier ones. Existing class URL helpers such as `OAuth2.token` retain their original URLs. Outside a request, use `composition.url_for(OAuth2, :token, ...)`; supply `mount_base:` to choose between repeated mounts.

### Independent compositions and catalogs

```crystal
composition = AC::Composition.new([MyApp.name, AnotherApp::Base.name])
server = AC::Server.new(composition: composition)
AC::MCPServer.mount(server, "/mcp")

docs = AC::OpenAPI.generate_open_api_docs(
  title: "Combined API", version: "1.0", composition: composition,
)
AC::MCPServer.write_description("combined-mcp.yml", composition: composition)
client = AC::SpecHelper.new(composition).hot_topic
```

For direct controller tests, `spec_instance` accepts the same composition and binds the requested mount's base and path parameters without executing actions or filters. Existing calls use the configured default composition:

```crystal
instance = OtherAC::App::OAuth2.spec_instance(
  HTTP::Request.new("GET", "/myapp/auth/token"), composition: composition,
)
instance.route_path(:token) # => "/myapp/auth/token"
```

OpenAPI uses public mounted paths and distinct operation IDs. MCP uses the same composition for tool calls, prompts, internal instructions, and relocated controller endpoints. Repeated mounts receive separate toolboxes and unique tool/prompt names. Existing visibility annotations and authentication settings still apply; the host owns global MCP configuration, session settings and UI asset locations.

For controller inheritance, the nearest controller with an `@[AC::MCP(...)]` annotation supplies defaults for both inherited and newly declared actions. A child controller annotation replaces those defaults; method annotations take precedence. Icons use the nearest controller that declares them; a method's icons take precedence. Children can change or disable inherited endpoints, enable an endpoint using inherited instructions, and override the instructions method.

MCP description caches are scoped to the composition and description file. Generated files include a composition identity incorporating the catalog version; a mismatched file is regenerated from compiled metadata without source comments. Regenerate descriptions with `--mcp` or `write_description` to retain those comments. Legacy description files remain supported for ordinary apps without explicit composition or mounts.

Controller selection, mount expansion, conflict validation and catalog projection run during compilation or initialization. `Server` registers all placements in one routing table. Exact static routes use the existing allocation-free lookup; other routes use LuckyRouter's compiled trie, copying captures only after a successful match and decoding escaped segments as required. Ordinary controller routes retain direct dispatch procs, which outperform the tested callable-object and integer dispatch alternatives with mixed targets. Relocated routes bind their public base on the request context, without allocating a placement or rewriting the request. Warmed MCP descriptions use atomic cache snapshots, without taking the catalog lock or hashing the composition. Explicit handler chains perform another lookup for every handler that misses. See [the performance benchmark](benchmarks/README.md) for repeatable comparisons and their limits.

### Compiled route snapshots

`Server.run` compiles the registered routes before binding/listening. Its binding
callback can register more endpoints; the updated routes are compiled again
before listening. This includes MCP endpoints added after server construction.
No template or configuration changes are required.

For a custom `HTTP::Server` setup, prepare a handler explicitly during startup:

```crystal
handler = MyApp.handler
handler.compile_routes
server = HTTP::Server.new([handler] of HTTP::Handler)
```

Handlers used directly also compile lazily on their first non-static lookup.
Adding a route invalidates the snapshot, which is rebuilt before the next trie
lookup. Warmed requests read an immutable snapshot without taking the compilation
lock. Exact static matches keep AC's existing lookup and path-binding behavior.

AC disables LuckyRouter's duplicate static index when that compile option is
available. Its static cache avoids allocating the empty parameter hash returned
by LuckyRouter's `match`. Snapshot compilation adds initialization time and
memory, and route definitions remain live for catalog generation and further
registration. See [the benchmark comparison](benchmarks/README.md) for measurements.

The compiled API is currently available in LuckyRouter's performance branch.
Released versions without it retain AC's previous matcher; versions with snapshots
but without the static-index option still compile with their default settings.
CI tests both the released dependency and the snapshot implementation.

## Strong Parameter Usage

```crystal
require "action-controller"

# Abstract classes don't generate routes
abstract class Application < ActionController::Base
  # A filter can raise or render to prevent a route being executed
  @[AC::Route::Filter(:before_action)]
  def ensure_authenticated
    render :unauthorized unless cookies["user"]?
  end

  # You can define controller level exception handlers for consistent error messages
  # note, the first param is always the error object
  @[AC::Route::Exception(AC::Route::Param::Error, status_code: HTTP::Status::BAD_REQUEST)]
  def route_param_error(error, id : Int64?)
    # as id is nillable, it will look for a supplied id (route, query, formdata)
    # and set it if one was found and it could be converted
    {
      error:       error.message,
      parameter:   error.parameter,
      restriction: error.restriction,
    }
  end
end

# Full inheritance support (concrete classes generate routes)
class Books < Application
  # this is automatically configured based on class name and namespace
  # it can be overriden here
  base "/books"

  # route => "/books/?book=1234"
  @[AC::Route::GET("/")]
  def index(book : UInt64? = nil) : Array(String)?
    # redirecting renders a response, so nothing is returned
    return redirect_to Books.show(id: book) if book
    ["book1", "book2"]
  end

  # Params are automatically extracted and converted to the correct type
  # here `id` in the route matches the `id` parameter in the function
  # route => "/books/0FF/hex"
  # route => "/books/123"
  @[AC::Route::GET("/:id/hex", config: {id: {base: 16}})]
  @[AC::Route::GET("/:id")]
  def show(id : UInt64) : NamedTuple(id: UInt64, name: String)
    {id: id, name: "book1"}
  end

  enum Colour
    Red
    Blue
    Green
  end

  # route => "/books/set_colour/RED"
  # route => "/books/set_colour/colour_value/2"
  @[AC::Route::GET("/set_colour/:colour")]
  @[AC::Route::GET("/set_colour/colour_value/:colour", config: {colour: {from_value: true}})]
  def set_colour(colour : Colour) : String
    colour.to_s
  end

  # a nilable enum param silently resolves to nil when the value doesn't parse.
  # `strict: true` raises `AC::Route::Param::ValueError` (bad request) instead,
  # while an absent param still resolves to the default
  # route => "/books/tint?colour=RED"
  @[AC::Route::GET("/tint", config: {colour: {strict: true}})]
  def tint(colour : Colour? = nil) : String
    colour.to_s
  end

  # Websocket support, the first param is always the socket object
  # route => "/books/:id/realtime"
  @[AC::Route::WebSocket("/:id/realtime")]
  def realtime(socket, id : UInt64)
    SOCKETS << socket

    socket.on_message do |message|
      SOCKETS.each { |sock| sock.send "Echo back from server: #{message}" }
    end

    socket.on_close do
      SOCKETS.delete(socket)
    end
  end

  SOCKETS = [] of HTTP::WebSocket
end
```

## MCP Server

Action Controller can expose your annotated routes to LLM clients as a
[Model Context Protocol](https://modelcontextprotocol.io) server using the
Streamable HTTP transport.

Controllers are presented as **toolboxes**, their route methods as **tools**, and methods
annotated with `@[AC::MCP(prompt: true)]` as **prompts**. To keep the model's context
lean, a session starts with just five tools, plus any [root items](#root-tools-and-prompts):

| tool | description |
|------|-------------|
| `list_toolboxes` | lists the controllers, their descriptions (the class comment), and their tool and prompt counts |
| `open_toolbox(name)` | adds the controller's tools and prompts to the session, sends `notifications/tools/list_changed` and/or `notifications/prompts/list_changed`, and returns the tool definitions |
| `close_toolbox(name)` | removes them again and sends the same notifications |
| `call_read_only(name, arguments)` | runs a read only tool from an open toolbox (or a root tool), for clients that don't refresh their tools when notified |
| `call_tool(name, arguments)` | runs any tool from an open toolbox (or a root tool), the same way. Both proxies refuse `visibility: :card` tools |

Some MCP clients (currently including Claude and ChatGPT) don't re-fetch their tools when
notified, so the opened tools never appear. `open_toolbox` returns each tool's name,
description, `inputSchema`, annotations and `proxy` (the proxy tool to run it with), and
the model runs them through the proxies instead. Calls through a proxy behave exactly
like direct calls.

There are two proxies so clients can tell reads from writes: `call_read_only` is hinted
`readOnlyHint: true` (so ChatGPT, for example, doesn't ask the user to confirm each call)
and refuses tools that aren't read only. A tool is read only if it's a GET route,
unless overridden with `@[AC::MCP(behaviour:)]`. Disable both proxies with
`MCPServer.tool_proxy = false` once your clients support `list_changed`.

Tool calls and prompts are dispatched in-process through the application router, so
filters, authentication, controller exception handlers and responders behave exactly
as they would for a regular HTTP request. (`Server.before` handlers are not run.)

### Setup

The MCP server is an optional feature:

```crystal
require "action-controller/server"
require "action-controller/mcp"

server = ActionController::Server.new
ActionController::MCPServer.mount(server, "/mcp")
server.run
```

`mount` registers `POST`, `GET` and `DELETE` handlers at the path provided, the OAuth
protected resource metadata at `/.well-known/oauth-protected-resource<path>`, and any
[controller endpoints](#controller-endpoints) (`endpoints: false` skips them).

### Tool descriptions (`mcp.yml`)

Like the OpenAPI generator, descriptions come from the comments in your source
code. Binaries don't ship with source, so you generate a description file at
build time and deploy it with the binary. It is lazily loaded the first time an
MCP client connects.

```crystal
# e.g. behind a `--mcp` command line switch in your app
if ARGV.includes?("--mcp")
  ActionController::MCPServer.write_description("mcp.yml")
  exit 0
end
```

Run it from the project root (it needs `crystal` and the source, like the OpenAPI
generator), then ship `mcp.yml` next to the binary:

```shell
crystal build src/app.cr -o bin/app
./bin/app --mcp
```

If the file is missing, the description is generated from the compiled routes
without the documentation comments, and a warning is logged.

The file contains, for each controller:

* the toolbox name (snake case controller name) and description (class comment).
  The module namespace shared by every controller is omitted, so
  `PlaceOS::Api::Zones` and `PlaceOS::Api::Groups::Users` become `zones` and
  `groups_users`
* a tool per controller method. A method with several route annotations is a single
  tool, using its first `GET` route (otherwise its first route)
  * the tool name, `<toolbox>_<method>`
  * the description, from the method comment
  * an input schema built from the route params, `@[AC::Param::Info]` descriptions
    and examples, and the request body
* a prompt per prompt method, named `<toolbox>_<method>`, with the method comment as
  the description and the arguments taken from the method params

Each tool's input schema is a self-contained JSON schema. Path, query and header
params are top-level properties, and the request body is the `body` property.

```crystal
# Manages the widgets in your account
class Widgets < AC::Base
  base "/widgets"

  # returns the widget requested
  @[AC::Route::GET("/:id")]
  def show(
    id : Int64,
    @[AC::Param::Info(description: "include usage stats", example: "true")]
    detailed : Bool = false,
  ) : Widget
    Widget.find(id, detailed)
  end
end
```

Here the toolbox `widgets` contains the tool `widgets_show`, which takes the
arguments `{"id": 1, "detailed": true}`.

WebSocket and `OPTIONS` routes, and routes without annotations, are not exposed.

### Prompts

[Prompts](https://modelcontextprotocol.io/specification/2025-11-25/server/prompts) are
reusable message templates that users select in their MCP client. Mark a controller
method with `@[AC::MCP(prompt: true)]`. It must return a `String`, which becomes a single
user message, or an `Array(AC::PromptMessage)` for a conversation:

```crystal
class Widgets < AC::Base
  base "/widgets"

  # summarise a widget for the user
  @[AC::MCP(prompt: true)]
  def summarise(
    id : Int64,
    @[AC::Param::Info(description: "the tone of the summary")]
    tone : String = "casual",
  ) : String
    "Summarise this widget in a #{tone} tone: #{Widget.find(id).to_json}"
  end

  # starts a widget review
  @[AC::MCP(prompt: true)]
  def review(id : Int64) : Array(AC::PromptMessage)
    [
      AC::PromptMessage.user("Review widget #{id}"),
      AC::PromptMessage.assistant("Which aspects should I focus on?"),
    ]
  end
end
```

* Prompts are **not HTTP routes**. They are only available to MCP clients and don't
  appear in the OpenAPI docs or route list.
* Arguments are parsed exactly like route params (converters, `config:`, defaults and
  `@[AC::Param::Info]`). Non-nilable arguments without a default are required.
* The controller's filters and exception handlers apply, so `before_action`
  authentication and model loading work as they do for routes. A filter that responds
  with `401` triggers re-authentication when [authentication](#authentication-optional) is
  enabled. Other errors are returned to the client as JSON-RPC errors.
* Prompts belong to their controller's toolbox and are listed once it's opened, unless
  they are root prompts.

### Root tools and prompts

Items marked `root: true` are always available, without opening a toolbox. Use this for
the handful of tools or prompts that most sessions need:

```crystal
class Widgets < AC::Base
  # always listed and callable
  @[AC::MCP(root: true)]
  @[AC::Route::GET("/colours")]
  def colours : Array(String)
    ["red", "green"]
  end

  # always listed
  @[AC::MCP(prompt: true, root: true)]
  def getting_started : String
    "Explain how to use the widget tools"
  end
end

# every route and prompt in the controller is a root item
@[AC::MCP(root: true)]
class Status < AC::Base
end
```

Root items keep their `<toolbox>_<method>` names. Toolboxes that only contain root items
are not listed by `list_toolboxes`.

### Controller endpoints

A controller can also be served as its own MCP server, for example one per account or
room. Annotate the class with `@[AC::MCP(endpoint: true)]` and it's served at
`<base>/mcp` (or a sub path, `endpoint: "/assistant"`):

```crystal
# Controls a room, look up its state before changing it
@[AC::MCP(endpoint: true)]
class Room < AC::Base
  base "/rooms/:room_id"

  # the room state
  @[AC::Route::GET("/state")]
  def state(room_id : String) : State
    State.for(room_id)
  end

  # turns the lights on or off
  @[AC::Route::POST("/lights")]
  def lights(room_id : String, on : Bool) : Nil
    Lights.set(room_id, on)
  end
end
```

Connecting to `/rooms/boardroom/mcp` lists `state` and `lights` directly:

* **Bound path params:** the base path params (`room_id`) come from the endpoint URL.
  They're left out of the tool arguments, and a session can only be used at the URL it
  was created at.
* **No toolboxes:** there are no meta tools or proxies, every tool and prompt is listed,
  named by its method.
* **Instructions:** the controller's doc comment is given to the model as the server's
  instructions, and the server is named after the controller. Define an `instructions`
  method to build them for each session instead:

  ```crystal
  # runs like a route when a client connects: filters run and path params are available
  def instructions(room_id : String) : String
    "You control the #{Room.find!(room_id).name}, look up its state before changing it."
  end
  ```

  It isn't an HTTP route or a tool. If it fails, for example the filters respond 403 or
  the room doesn't exist, the client can't connect: `initialize` returns the error (a 401
  challenges the client to sign in again).
* **Visibility:** the controller is hidden from the global server unless it's also
  annotated `hide: false`. A method annotated `hide: true` is hidden from both.
* **Shared configuration:** authentication, forwarded headers and tool results use the
  `MCPServer` configuration, and tool calls run the controller's filters, so check access
  to the room (or account) in a `before_action`. The protected resource metadata is
  served for each endpoint URL.

`MCPServer.mount` mounts the endpoints too (`endpoints: false` skips them), and
`write_description` includes them in `mcp.yml`.

### UI cards (MCP Apps)

Tools can render an interactive HTML card in the conversation, using the
[MCP Apps](https://github.com/modelcontextprotocol/ext-apps) extension supported by
Claude, ChatGPT, VS Code and Microsoft 365 Copilot. Cards are static HTML files in a
folder:

```crystal
ActionController::MCPServer.ui_base = "./cards"
# the default card settings, a card can override them with a `<card>.meta.json` file
ActionController::MCPServer.ui_meta = ActionController::MCPServer::UIMeta.new(prefers_border: true)

class Bookings < AC::Base
  base "/bookings"

  # Shows a booking
  @[AC::MCP(ui: "bookings/card.html")] # ./cards/bookings/card.html
  @[AC::Route::GET("/:id")]
  def show(id : String) : Booking
    Booking.find!(id)
  end

  # Checks in to a booking, only the card can call this
  @[AC::MCP(visibility: :card)]
  @[AC::Route::POST("/:id/check_in")]
  def check_in(id : String) : Booking
    Booking.find!(id).check_in!
  end
end
```

* **How it works:** the tool's `_meta.ui.resourceUri` points at the card
  (`ui://bookings/card.html`). The host reads it with `resources/read` and renders it in a
  sandboxed iframe. It sends the card the tool's arguments and its result, the
  `{status, headers, body}` envelope as `structuredContent`.
* **Cards** are self-contained HTML5 documents. By default hosts allow inline scripts and
  styles, but no external resources or network requests. Declare any domains a card needs
  in `ui_meta`, or in a sidecar such as `bookings/card.meta.json`:
  `{"csp": {"resourceDomains": ["https://cdn.example.com"]}, "prefersBorder": false}`.
* **Talking to the host:** cards use JSON-RPC over `postMessage` (`ui/initialize`, then
  `ui/notifications/tool-result`), with or without the `@modelcontextprotocol/ext-apps`
  SDK. They can call tools too, such as `visibility: :card` tools.
* **Caching:** hosts cache cards by URI, so tools advertise
  `ui://bookings/card.html?v=<content hash>`. A changed card gets a new URI.
* **Root by default:** hosts only render cards for, and let cards call, the tools in
  their tool list. So tools with `ui:` or `visibility: :card` are root items, listed without
  opening their toolbox, unless annotated `root: false`.
* `ui:` paths are relative to `ui_base` and must be `.html` files (checked at compile
  time). Nothing outside `ui_base` is served. Hosts without MCP Apps support ignore the
  card metadata and show the text result.

### Connecting a client

Point any MCP client that supports Streamable HTTP at the mounted path, for example
with Claude Code:

```shell
claude mcp add --transport http my-app http://localhost:3000/mcp \
  --header "Authorization: Bearer <token>"
```

Headers in `forward_headers` (by default `Authorization`, `Cookie` and `X-API-Key`) are
copied onto every tool call, so your existing authentication filters apply.

### Authentication (optional)

By default the MCP endpoint itself is open. Anyone can connect and browse the
toolboxes, and each tool call is authenticated by your routes using the forwarded
headers. A route that responds with `401` is reported to the model as a tool error.

This works well for static credentials such as API keys, but MCP clients only sign
in, or refresh an expired token, when the **MCP endpoint itself** responds with
HTTP `401` and a `WWW-Authenticate` challenge. Enable authentication to get that
behaviour. It is enabled when any of the following are configured.

**Validating credentials:** choose one of these.

```crystal
# a route that requires authentication, requested in-process with the forwarded headers.
# A 2xx response means the request is authenticated, no shared code required
ActionController::MCPServer.auth_probe = "/api/users/current"

# or a custom check
ActionController::MCPServer.authenticator = ->(request : HTTP::Request) do
  MyAuth.valid_token?(request.headers["Authorization"]?)
end
```

**Advertising your OAuth authorization server:** this lets clients sign in
interactively and refresh tokens automatically. It uses
[RFC 9728](https://www.rfc-editor.org/rfc/rfc9728) protected resource metadata,
served at `/.well-known/oauth-protected-resource/mcp` (`/mcp` being the mount
path). The block receives the request, so multi-tenant applications can respond
per host.

```crystal
ActionController::MCPServer.resource_metadata = ->(request : HTTP::Request) do
  ActionController::MCPServer::ResourceMetadata.new(
    authorization_servers: ["https://#{request.hostname}"],
    scopes_supported: ["public"],
  )
end
```

The authorization server must publish
[RFC 8414](https://www.rfc-editor.org/rfc/rfc8414) metadata and support the
authorization code flow with PKCE. MCP clients also need a way to obtain a client
id: dynamic client registration, client ID metadata documents, or a pre-registered
client. Without `authenticator` or `auth_probe`, requests only need to present
credentials, and invalid ones are rejected when a tool is called.

When authentication is enabled:

* Every `POST`, `GET` and `DELETE` to the MCP endpoint is checked, including
  `initialize`. A failure returns `401` with
  `WWW-Authenticate: Bearer resource_metadata="…", scope="…", error="invalid_token"`.
  The `resource_metadata` and `scope` parameters are included when `resource_metadata` is configured.
* Successful checks are cached per credential for `auth_cache_ttl` (default 1 minute),
  so the probe isn't run for every message.
* If a tool call is rejected by a route with `401`, for example because the token
  expired mid-session, the MCP endpoint returns HTTP `401` instead of a tool error.
  The client then refreshes its token and retries. A `403` is still reported to the model as a tool error.

Choosing an approach:

| Scenario | Configuration |
|----------|---------------|
| Public or anonymous API | nothing |
| Agents with long lived credentials | nothing, or `auth_probe` to reject bad keys at connect time. Clients send a header, e.g. `--header "X-API-Key: …"` |
| Interactive users with OAuth | `auth_probe` (or `authenticator`) + `resource_metadata` |

For example, a multi-tenant API whose tokens are issued by an OAuth server on the same host:

```crystal
ActionController::MCPServer.tap do |mcp|
  mcp.auth_probe = "/api/engine/v2/users/current"
  mcp.resource_metadata = ->(request : HTTP::Request) do
    ActionController::MCPServer::ResourceMetadata.new(
      authorization_servers: ["https://#{request.hostname}"],
      scopes_supported: ["public"],
    )
  end
end
```

### Annotation options and hiding routes

`@[AC::MCP]` options can be applied to a controller or a method, and the method level
annotation takes precedence:

| option | description |
|--------|-------------|
| `hide: true` | excludes the routes / prompts from MCP |
| `root: true` | always available, without opening the toolbox |
| `prompt: true` | the method is an MCP prompt (methods only) |
| `title: "Book a room"` | the tool or prompt's display name (methods only) |
| `behaviour: :read_only` | what the tool does, see below |
| `visibility: :card` | who can call the tool: `:model`, `:card` or both (the default) |
| `ui: "bookings/card.html"` | renders this HTML card for the tool's results, see [UI cards](#ui-cards-mcp-apps) |
| `endpoint: true` | serves the controller as its own MCP server at `<base>/mcp` (controllers only), see [controller endpoints](#controller-endpoints) |

Tools with `ui:` or `visibility: :card` default to `root: true`.

**Behaviour** tells hosts what a tool does, which they use to decide what to confirm with
the user. It's a symbol or an array of `:read_only`, `:additive`, `:destructive`,
`:idempotent`, `:open_world` and `:closed_world`. By default it's inferred from the HTTP
verb: GET is `:read_only`, PUT is `:idempotent` and DELETE is
`[:destructive, :idempotent]`. Setting it replaces the default, and contradictions are
compile errors. Read only tools can be run with the `call_read_only` proxy.

```crystal
@[AC::MCP(behaviour: :read_only)]                # a POST search
@[AC::MCP(behaviour: [:additive, :open_world])]  # a POST that sends an email
@[AC::MCP(behaviour: :destructive)]              # a PUT that replaces data
```

**Visibility** controls who can call a tool in hosts that support
[UI cards](#ui-cards-mcp-apps): `:card` tools are hidden from the model, and `:model`
tools can't be called by cards. Hosts enforce it, and the `call_tool` and
`call_read_only` proxies refuse `:card` tools, but it isn't access control: a client can
still call a tool by name.

**Upgrading:** `read_only:` was replaced by `behaviour:` (`read_only: true` is
`behaviour: :read_only`), and `card_only:` by `visibility: :card`. The old names are
compile errors. Regenerate `mcp.yml` after upgrading.

**Icons** are added with `@[AC::Icon]`, which you can repeat for different sizes and
themes. On a controller they're the default for its tools and prompts, and the icon of
its toolbox and [endpoint](#controller-endpoints):

```crystal
@[AC::Icon(src: "icons/book.svg", sizes: ["any"])]
@[AC::Icon(src: "icons/book-dark.svg", sizes: ["any"], theme: "dark")]
@[AC::Route::POST("/")]
def create(booking : Booking) : Booking
```

`src` is sent as is when it's an `https:` or `data:` URL. A file in `MCPServer.ui_base`
is sent as a `data:` URL, and anything else is a path on the current host. Every other
argument is passed through as is. Use `MCPServer.icon "icons/logo.svg", sizes: ["any"]`
for the server's own icon.

```crystal
@[AC::MCP(hide: true)] # hide every route in the controller
class Internal < AC::Base
  @[AC::MCP(hide: false)] # method annotations take precedence
  @[AC::Route::GET("/status")]
  def status : String
    "ok"
  end
end
```

### Configuration

```crystal
ActionController::MCPServer.tap do |mcp|
  mcp.description_path = "mcp.yml"                 # relative to the working directory
  mcp.server_name = "my-app"
  mcp.server_version = "1.2.0"
  mcp.instructions = "About my-app. #{mcp.toolbox_instructions}" # nil (default): toolbox usage only, "": none
  mcp.tool_proxy = true                           # the call_read_only and call_tool meta tools
  mcp.forward_headers = ["Authorization", "Cookie", "X-API-Key"] # copied onto tool requests
  mcp.allowed_origins = ["https://app.example.com"]              # "*" allows any origin
  mcp.session_timeout = 30.minutes
  mcp.excluded_response_headers += ["X-Runtime"]  # left out of tool results, `*` matches a prefix
  mcp.icon "icons/logo.svg", sizes: ["any"]       # the server's icon, see Icons above

  # UI cards (MCP Apps), see above
  mcp.ui_base = "./cards"
  mcp.ui_meta = ActionController::MCPServer::UIMeta.new(prefers_border: true)

  # authentication, all optional (see above)
  mcp.auth_probe = "/api/users/current"
  mcp.authenticator = ->(request : HTTP::Request) { true }
  mcp.auth_cache_ttl = 1.minute
  mcp.resource_metadata = ->(request : HTTP::Request) do
    ActionController::MCPServer::ResourceMetadata.new(authorization_servers: ["https://auth.example.com"])
  end
end
```

### Transport notes

* Implements Streamable HTTP for protocol versions `2025-11-25`, `2025-06-18` and `2025-03-26`.
* `POST` returns `application/json`, unless the call produced notifications and the client
  accepts `text/event-stream`. In that case the notifications are streamed ahead of the result.
* `GET` with `Accept: text/event-stream` opens a stream for server notifications.
* `DELETE` ends the session.
* `Origin` headers must be same-origin or listed in `allowed_origins`, which protects against DNS rebinding.
* Sessions are stored in memory per process. Multi-node deployments need sticky sessions.
  Sessions are not credentials: when authentication is enabled every request must be authenticated.
* Unhandled exceptions raised by a route are logged and returned as a generic `500` tool error.
* Clients that support `notifications/tools/list_changed` see the tools added by
  `open_toolbox` directly, others use `call_read_only` and `call_tool`. Prompts added by a toolbox need
  `notifications/prompts/list_changed`. Root items don't require either.

### Tool results

A tool call returns the route's response as `{status, headers, body}`, both as the text
content and as `structuredContent`:

```json
{
  "status": 200,
  "headers": {"X-Total-Count": "120", "Link": "</api/users?page=2>; rel=\"next\""},
  "body": [{"id": 1, "name": "Steve"}]
}
```

* `body` is the parsed JSON, or the text of any other response. It's left out when empty,
  and so is `headers`.
* Headers matching `excluded_response_headers` are left out. By default these are
  `Date`, `Content-Length`, `X-Request-ID`, `Content-Type`, cookies and credentials,
  transport headers (`Connection`, `Transfer-Encoding` ...) and browser policy headers
  (`Strict-Transport-Security`, `Access-Control-*` ...). Everything else, such as
  `Link`, `X-Total-Count`, `Content-Range` and `Location`, is returned so the model can
  page through results.
* Responses with a status of 400 or above set `isError` (except `401` when
  authentication is enabled, see above).
* Images and audio are returned as an `image` or `audio` content block, followed by the
  envelope without a body.

## More information

* For more details on usage, see [the documentation](https://spider-gazelle.net/).
* Also see [detailed project documentation](https://spider-gazelle.github.io/action-controller/ActionController.html)
* Running heavy endpoints on dedicated scheduler pools: [Execution Contexts](CONTEXTS.md)
