# Run with: crystal build --release -o /tmp/ac-router-bench bench/router.cr
# Then: /tmp/ac-router-bench [iterations] [case] [route_pairs] [simple]
require "../src/action-controller"

alias Router = ActionController::Router
alias Action = Router::Action

iterations = (ARGV[0]?.try(&.to_i) || 1_000_000)
selected_case = ARGV[1]?
route_pairs = (ARGV[2]?.try(&.to_i) || 100)
simple_only = ARGV[3]? == "simple"
raise "iterations must be positive" unless iterations > 0
raise "route_pairs must be at least 43" unless route_pairs >= 43

handler = Router::RouteHandler.new
action = ->(context : HTTP::Server::Context, _head : Bool) { context }
route_pairs.times do |index|
  handler.add_route("GET", "/catalog/item#{index}", {action, false})
  handler.add_route("GET", "/catalog/category#{index}/:id", {action, false})
end
handler.add_route("GET", "/catalog/:category/:id", {action, false}) unless simple_only

request = HTTP::Request.new("GET", "/catalog/category42/123")
context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))

cases = {
  "static-hit"   => "/catalog/item42",
  "dynamic-hit"  => "/catalog/category42/123",
  "fallback-hit" => "/catalog/unknown/123",
  "miss"         => "/catalog/missing/123/extra",
}

raise "unknown case: #{selected_case}" if selected_case && !cases.has_key?(selected_case)

puts "Crystal #{Crystal::VERSION}, iterations=#{iterations}, routes=#{2 * route_pairs + (simple_only ? 0 : 1)}"
cases.each do |label, path|
  next if selected_case && label != selected_case
  # Use the same context object so this measurement isolates route lookup.
  # A different request context is necessary for allocation-per-request tests.
  10_000.times { handler.search_route("GET", path, context) }
  GC.collect
  before = GC.stats
  checksum = 0
  started = Time.instant
  iterations.times do
    result = handler.search_route("GET", path, context)
    checksum += result ? 1 : 0
  end
  elapsed = Time.instant - started
  after = GC.stats
  ns_per_op = elapsed.total_nanoseconds / iterations
  bytes_per_op = (after.total_bytes - before.total_bytes) / iterations
  puts "#{label.ljust(13)} #{ns_per_op.round(1)} ns/op #{bytes_per_op.round(1)} B/op checksum=#{checksum}"
end
