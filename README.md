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
    render :unauthorized unless cookies["user"]
  end

  # You can define controller level exception handlers for consistent error messages
  # note, the first param is always the error object
  @[AC::Route::Exception(Route::Param::Error, status_code: :not_found)]
  def route_param_error(error, id : Int64?)
    # as id is nillable, it will look for a supplied id (route, query, formdata)
    # and set it if one was found and it could be converted
    {
      error: error.message,
      parameter: error.parameter,
      restriction: error.restriction
    }
  end
end

# Full inheritance support (concrete classes generate routes)
class Books < Application
  # this is automatically configured based on class name and namespace
  # it can be overriden here
  base "/books"

  # route => "/books/?book=1234"
  @[Route::GET("/")]
  def index(book : UInt64? = nil) : Array(String)
    redirect_to Books.show(id: book) if book
    ["book1", "book2"]
  end

  # Params are automatically extracted and converted to the corrent type
  # here `id` in the route matches the `id` paramater in the function
  # route => "/books/0FF/hex"
  # route => "/books/123"
  @[Route::GET("/:id/hex", config: {id: {base: 16}})]
  @[Route::GET("/:id")]
  def show(id : UInt64)
    {id: id, name: "book1"}
  end

  enum Color
    Red
    Blue
    Green
  end

  # route => "/books/set_color/RED"
  # route => "/books/set_color/colour_value/2"
  @[Route::GET("/set_color/:colour")]
  @[Route::GET("/set_color/colour_value/:colour", config: {colour: {from_value: true}})]
  def set_color(color : Color) : String
    colour.to_s
  end

  # a nilable enum param silently resolves to nil when the value doesn't parse.
  # `strict: true` raises `AC::Route::Param::ValueError` (bad request) instead,
  # while an absent param still resolves to the default
  # route => "/books/tint?colour=RED"
  @[Route::GET("/tint", config: {colour: {strict: true}})]
  def tint(colour : Color? = nil) : String
    colour.to_s
  end

  # Websocket support, the first param is always the socket object
  # route => "/books/:id/realtime"
  @[AC::Route::WebSocket("/:id/realtime")]
  def realtime(socket, id : UInt64)
    SOCKETS << socket

    socket.on_message do |message|
      SOCKETS.each { |socket| socket.send "Echo back from server: #{message}" }
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

Controllers are presented as **toolboxes** and their routes as **tools**. To keep the
model's context lean, a session starts with just three tools:

| tool | description |
|------|-------------|
| `list_toolboxes` | lists the controllers, their descriptions (the class comment) and tool counts |
| `open_toolbox(name)` | adds the controller's routes to the session's tools and sends `notifications/tools/list_changed` |
| `close_toolbox(name)` | removes them again and sends `notifications/tools/list_changed` |

Tool calls are dispatched in-process through the application router, so filters,
authentication, controller exception handlers and responders behave exactly as they
would for a regular HTTP request. (`Server.before` handlers are not run for tool calls.)

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

* the toolbox name (snake case controller name) and description (class comment)
* a tool per route
  * the tool name, `<toolbox>_<method>`
  * the description, from the method comment
  * an input schema built from the route params, `@[AC::Param::Info]` descriptions
    and examples, and the request body

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

### Connecting a client

Point any MCP client that supports Streamable HTTP at the mounted path, for example
with Claude Code:

```shell
claude mcp add --transport http my-app http://localhost:3000/mcp \
  --header "Authorization: Bearer <token>"
```

Headers in `forward_headers` (by default `Authorization` and `Cookie`) are copied
onto every tool call, so your existing authentication filters apply.

### Hiding routes

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
  mcp.forward_headers = ["Authorization", "Cookie"] # copied onto tool requests
  mcp.allowed_origins = ["https://app.example.com"] # "*" allows any origin
  mcp.session_timeout = 30.minutes
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
* Tool results contain the response body as text. Successful JSON object responses
  are also provided as `structuredContent`, and responses with a status of 400 or above set `isError`.
* Clients must support `notifications/tools/list_changed` to see tools added by `open_toolbox`.
* Unhandled exceptions raised by a route are logged and returned as a generic `500` tool error.

## More information

* For more details on usage, see [the documentation](https://spider-gazelle.net/).
* Also see [detailed project documentation](https://spider-gazelle.github.io/action-controller/ActionController.html)
* Running heavy endpoints on dedicated scheduler pools: [Execution Contexts](CONTEXTS.md)
