require "../src/action-controller"
require "../src/action-controller/server"
require "../src/action-controller/mcp"

# Run with `crystal run --release benchmarks/composition.cr` in both checkouts.
# Startup, catalog generation and the first lookup are excluded from measurements.
class BenchmarkPages < AC::Base
  base "/bench"

  @[AC::Route::GET("/")]
  def index : String
    "ok"
  end

  @[AC::Route::GET("/:id")]
  def show(id : Int32) : String
    id.to_s
  end
end

class NativeBenchmarkPages < AC::Base
  base "/native"

  @[AC::Route::GET("/")]
  def index : String
    "ok"
  end

  @[AC::Route::GET("/:id")]
  def show(id : Int32) : String
    id.to_s
  end
end

def context(path : String, response : HTTP::Server::Response = HTTP::Server::Response.new(IO::Memory.new))
  HTTP::Server::Context.new(HTTP::Request.new("GET", path), response)
end

def dispatch(router, path, response)
  # Match HTTP::Server's keep-alive behavior: fresh context, reusable response buffer.
  response.reset
  router.call(context(path, response))
end

def measure(name : String, iterations : Int32, &)
  10_000.times { yield }
  timings = [] of Float64
  allocations = [] of Float64
  9.times do
    GC.collect
    before_bytes = GC.stats.total_bytes
    start = Time.instant
    iterations.times { yield }
    timings << (Time.instant - start).total_nanoseconds / iterations
    allocations << (GC.stats.total_bytes - before_bytes).to_f / iterations
  end
  puts "#{name}: #{timings.sort[4].round(1)} ns/op, #{allocations.sort[4].round(1)} bytes/op"
end

Log.setup :none
server = ActionController::Server.new
router = server.route_handler
static_context = context("/bench")
dynamic_context = context("/bench/7")
miss_context = context("/unknown")
response = HTTP::Server::Response.new(IO::Memory.new)
ActionController::MCPServer.description = ActionController::MCPServer.generate_description

measure("static lookup", 500_000) { router.search_route("GET", "/bench", static_context) }
measure("dynamic lookup", 200_000) { router.search_route("GET", "/bench/7", dynamic_context) }
measure("miss lookup", 500_000) { router.search_route("GET", "/unknown", miss_context) }
measure("static dispatch with fresh context", 100_000) { dispatch(router, "/bench", response) }
measure("dynamic dispatch with fresh context", 100_000) { dispatch(router, "/bench/7", response) }
measure("static URL helper", 200_000) { BenchmarkPages.index }
measure("dynamic URL helper", 200_000) { BenchmarkPages.show(id: 7) }
measure("cached MCP description", 500_000) { ActionController::MCPServer.description }

invoker = ActionController::MCPServer::Invoker.new(router)
protocol = ActionController::MCPServer::Protocol.new(invoker)
session = ActionController::MCPServer::Session.new("2025-11-25")
ActionController::MCPServer.description.toolboxes.each { |box| session.open(box.name) }
params = {} of String => JSON::Any
request = HTTP::Request.new("POST", "/mcp")
emitted = [] of String
measure("MCP tools/list", 100_000) { protocol.handle("tools/list", params, session, request, emitted) }

# A relocated placement uses exactly the same registration as a declarative mount.
# Compare it with a controller declared directly at the resulting base.
# Include these cases with `-Dcomposable_benchmark` on the composition branch.
{% if flag?(:composable_benchmark) %}
  definition = ActionController::Composition.controllers.find!(&.name.==("BenchmarkPages"))
  mounted = ActionController::Composition.new([ActionController::Composition::Placement.new(definition, "/native")], true).route_handler
  measure("native static dispatch", 100_000) { dispatch(router, "/native", response) }
  measure("mounted static dispatch", 100_000) { dispatch(mounted, "/native", response) }
  measure("native dynamic dispatch", 100_000) { dispatch(router, "/native/7", response) }
  measure("mounted dynamic dispatch", 100_000) { dispatch(mounted, "/native/7", response) }
{% end %}
