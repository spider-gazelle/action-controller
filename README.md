# Spider-Gazelle Action Controller

[![CI](https://github.com/spider-gazelle/action-controller/actions/workflows/ci.yml/badge.svg)](https://github.com/spider-gazelle/action-controller/actions/workflows/ci.yml)

A fast, type-safe web framework for [Crystal](https://crystal-lang.org). Write a method
with typed arguments and a return type, and Action Controller parses the request, renders
the response, documents the route in OpenAPI and serves it to AI agents over MCP.

**Read the guide at [spider-gazelle.net](https://spider-gazelle.net/).**

## Features

* **Strong parameters:** path, query, header, form and body values become typed
  arguments, and invalid input is rejected before your code runs.
* **OpenAPI 3.1 generation:** the document is built from your routes, types and doc
  comments, so it stays in step with the code.
* **MCP server:** your routes become tools that Claude, ChatGPT and other agents can
  call through your filters and authentication, with prompts, resources, subscriptions
  and UI cards.
* **Content negotiation:** JSON and YAML out of the box, plus your own parsers and
  responders. Binary types, such as [BinData](https://github.com/spider-gazelle/bindata),
  are read and written as they are.
* **Filters, exception handlers and WebSockets,** declared with annotations and inherited
  by subclasses.
* **Composable applications:** mount controllers or whole apps under other paths, with
  one routing table, OpenAPI document and MCP server.
* **Performance:** routes compile into a single routing trie with direct dispatch, and
  heavy routes can run on their own [execution contexts](CONTEXTS.md). See how it
  compares in the [web frameworks benchmark](https://web-frameworks-benchmark.netlify.app/result?l=crystal).

## Installation

Start from the [application template](https://github.com/spider-gazelle/spider-gazelle),
which includes logging, specs, Docker, OpenAPI and MCP, or add the shard to `shard.yml`:

```yaml
dependencies:
  action-controller:
    github: spider-gazelle/action-controller
```

See [your first app](https://spider-gazelle.net/getting_started/) for a walkthrough.

## Strong parameters

Arguments are read from the path, query string, headers or body by name, and converted
to their type. A required argument that's missing, or a value that doesn't convert,
raises an error your controller can turn into a `400`:

```crystal
require "action-controller"

abstract class Application < ActionController::Base
  @[AC::Route::Exception(AC::Route::Param::Error, status_code: HTTP::Status::BAD_REQUEST)]
  def invalid_param(error) : NamedTuple(error: String?, parameter: String?)
    {error: error.message, parameter: error.parameter}
  end
end

# Manages the books in the library
class Books < Application
  base "/books"

  struct Book
    include JSON::Serializable
    getter title : String
    getter year : Int32

    def initialize(@title, @year)
    end
  end

  enum Genre
    Fiction
    History
    Science
  end

  # Searches the catalogue
  # GET /books?genre=history&tag=war&tag=empire&limit=5
  @[AC::Route::GET("/")]
  def index(
    genre : Genre? = nil,
    tag : Array(String) = [] of String,
    @[AC::Param::Info(description: "results per page")]
    limit : Int32 = 20,
  ) : Array(Book)
    [] of Book
  end

  # Fetches a book by its ID, in decimal or hex
  # GET /books/42 or /books/2A/hex
  @[AC::Route::GET("/:id")]
  @[AC::Route::GET("/:id/hex", config: {id: {base: 16}})]
  def show(id : UInt64) : Book
    Book.new(title: "Dune", year: 1965)
  end

  # Adds a book
  @[AC::Route::POST("/", body: :book, status_code: HTTP::Status::CREATED)]
  def create(book : Book) : Book
    book
  end
end
```

Optional arguments take their default, enums parse by name or value, arrays and sets
collect every repetition of a name, and custom converters handle anything else. See
[parameters](https://spider-gazelle.net/guides/parameters/) and
[responses](https://spider-gazelle.net/guides/responses/).

## OpenAPI

The routes above describe themselves: paths, parameters, schemas for `Book` and
`Genre`, status codes, and the doc comments as summaries. Generate the document with the
template's `--docs` flag, or in code:

```crystal
docs = ActionController::OpenAPI.generate_open_api_docs(title: "Library", version: "1.0.0")
File.write("openapi.yml", docs.to_yaml)
```

See [OpenAPI](https://spider-gazelle.net/openapi/).

## MCP server

Mount the [Model Context Protocol](https://modelcontextprotocol.io) server and every
annotated route is a tool, described by the same comments and types:

```crystal
require "action-controller/server"
require "action-controller/mcp"

server = ActionController::Server.new
ActionController::MCPServer.mount(server, "/mcp")
server.run
```

Calls are dispatched through the router with the client's headers, so filters,
authentication and exception handlers apply as they do to any request. Controllers are
listed as toolboxes to keep the model's context small, and `@[AC::MCP(...)]` adds
prompts, resources and UI cards. See [MCP](https://spider-gazelle.net/mcp/).

## More information

* [The guide](https://spider-gazelle.net/): routing, filters, errors, sessions,
  WebSockets, testing, composition and deployment
* [API reference](https://spider-gazelle.github.io/action-controller/ActionController.html)
* [Execution contexts](CONTEXTS.md): run heavy routes on dedicated scheduler pools
* [Web frameworks benchmark results](https://web-frameworks-benchmark.netlify.app/result?l=crystal),
  and the [routing benchmarks](benchmarks/README.md) in this repo
