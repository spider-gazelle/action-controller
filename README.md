# Spider-Gazelle Action Controller

[![CI](https://github.com/spider-gazelle/action-controller/actions/workflows/ci.yml/badge.svg)](https://github.com/spider-gazelle/action-controller/actions/workflows/ci.yml)

Extending [lucky_router](https://github.com/luckyframework/lucky_router) for a Rails like DSL without the overhead. See the [docs site](https://spider-gazelle.net/) for usage details

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
lean, a session starts with just three tools, plus any [root items](#root-tools-and-prompts):

| tool | description |
|------|-------------|
| `list_toolboxes` | lists the controllers, their descriptions (the class comment), and their tool and prompt counts |
| `open_toolbox(name)` | adds the controller's tools and prompts to the session and sends `notifications/tools/list_changed` and/or `notifications/prompts/list_changed` |
| `close_toolbox(name)` | removes them again and sends the same notifications |

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

`mount` registers `POST`, `GET` and `DELETE` handlers at the path provided.

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

WebSocket routes and routes without annotations are not exposed.

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
  mcp.instructions = "..."                         # guidance provided to the model
  mcp.forward_headers = ["Authorization", "Cookie", "X-API-Key"] # copied onto tool requests
  mcp.allowed_origins = ["https://app.example.com"]              # "*" allows any origin
  mcp.session_timeout = 30.minutes

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
* Tool results contain the response body as text. Successful JSON object responses
  are also provided as `structuredContent`, and responses with a status of 400 or above set `isError`
  (except `401` when authentication is enabled, see above).
* Clients must support `notifications/tools/list_changed` and `notifications/prompts/list_changed`
  to see the tools and prompts added by `open_toolbox`. Root items don't require them.
* Unhandled exceptions raised by a route are logged and returned as a generic `500` tool error.

## More information

* For more details on usage, see [the documentation](https://spider-gazelle.net/).
* Also see [detailed project documentation](https://spider-gazelle.github.io/action-controller/ActionController.html)
* Running heavy endpoints on dedicated scheduler pools: [Execution Contexts](CONTEXTS.md)
