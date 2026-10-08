require "./router_strategy"
require "http/client/response"

# The same routes and filters are used for the original and mounted app.
macro warmed_routes
  before_action :mark_request

  def mark_request(counter : Int32 = 1)
    response.headers["X-Counter"] = counter.to_s
  end

  {% for index in 0...16 %}
    @[AC::Route::GET({{ "/static/#{index}" }})]
    def {{ "static_#{index}".id }} : String
      "ok"
    end
  {% end %}

  @[AC::Route::GET("/:id")]
  def show(id : Int32) : String
    id.to_s
  end

  @[AC::Route::GET("/:account_id/nested/:id")]
  def nested(account_id : Int32, id : Int32) : String
    "#{account_id}:#{id}"
  end

  @[AC::Route::GET("/base")]
  def public_base : String
    base_route
  end
end

class WarmedPages < AC::Base
  base "/app"
  warmed_routes
end

class WarmedNativePages < AC::Base
  base "/mounted"
  warmed_routes
end

{% if flag?(:composable_benchmark) %}
  class WarmedHost < AC::Base
    base "/mounted"
    mount "/", WarmedPages
  end
{% end %}

# Equivalent to the original server's single route handler.
class WarmedRouter
  include AC::Router

  def call(context : HTTP::Server::Context)
    route_handler.call(context)
  end
end

def measure(name : String, handler, path : String, expected : String)
  output = IO::Memory.new
  response = HTTP::Server::Response.new(output)
  # Check behavior before timing, including filters and the mounted base.
  handler.call(HTTP::Server::Context.new(HTTP::Request.new("GET", path), response))
  response.close
  output.rewind
  parsed = HTTP::Client::Response.from_io(output)
  raise "incorrect body for #{name}" unless parsed.body == expected.to_json
  raise "missing filter for #{name}" unless response.headers["X-Counter"] == "1"

  output.clear
  20_000.times do
    response.reset
    handler.call(HTTP::Server::Context.new(HTTP::Request.new("GET", path), response))
  end
  timings = [] of Float64
  allocations = [] of Float64
  15.times do
    GC.collect
    before = GC.stats.total_bytes
    start = Time.instant
    100_000.times do
      response.reset
      handler.call(HTTP::Server::Context.new(HTTP::Request.new("GET", path), response))
    end
    timings << (Time.instant - start).total_nanoseconds / 100_000
    allocations << (GC.stats.total_bytes - before).to_f / 100_000
  end
  puts({name: name, ns: timings.sort[7], bytes: allocations.sort[7]}.to_json)
end

Log.setup :none
single = {% if flag?(:composable_benchmark) %} WarmedPages.handler {% else %} WarmedRouter.new {% end %}
mounted = {% if flag?(:composable_benchmark) %} WarmedHost.handler {% else %} WarmedRouter.new {% end %}
{% unless flag?(:composable_benchmark) %}
  WarmedPages.__init_routes__(single)
  WarmedNativePages.__init_routes__(mounted)
{% end %}

# Match server.run's startup preparation without listening on a socket.
{% if ActionController::Router::RouteHandler.has_method?(:compile_routes) %}
  single.route_handler.compile_routes
  mounted.route_handler.compile_routes
{% end %}

measure("single static", single, "/app/static/7", "ok")
measure("single dynamic", single, "/app/7", "7")
measure("single nested", single, "/app/42/nested/7", "42:7")
measure("single base accessor", single, "/app/base", "/app")
measure("mounted static", mounted, "/mounted/static/7", "ok")
measure("mounted dynamic", mounted, "/mounted/7", "7")
measure("mounted nested", mounted, "/mounted/42/nested/7", "42:7")
measure("mounted base accessor", mounted, "/mounted/base", "/mounted")
