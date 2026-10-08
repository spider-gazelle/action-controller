require "./router_strategy"

private def measure_lookup(name : String, handler, method : String, path : String, expected : Hash(String, String)?)
  context = HTTP::Server::Context.new(HTTP::Request.new(method, "/"), HTTP::Server::Response.new(IO::Memory.new))
  result = handler.search_route(method, path, context)
  raise "incorrect result for #{name}" unless !!result == !expected.nil?
  raise "incorrect params for #{name}" if expected && context.route_params != expected
  raise "incorrect HEAD flag" if result && result[1] != (method == "HEAD")

  checksum = 0_u64
  20_000.times { checksum &+= handler.search_route(method, path, context) ? 1_u64 : 0_u64 }
  timings = [] of Float64
  allocations = [] of Float64
  9.times do
    GC.collect
    before = GC.stats.total_bytes
    start = Time.instant
    200_000.times { checksum &+= handler.search_route(method, path, context) ? 1_u64 : 0_u64 }
    timings << (Time.instant - start).total_nanoseconds / 200_000
    allocations << (GC.stats.total_bytes - before).to_f / 200_000
  end
  puts({name: name, ns: timings.sort[4], bytes: allocations.sort[4], checksum: checksum}.to_json)
end

handler = ActionController::Router::RouteHandler.new
handler.isolate_path_params = true
action = ->(context : HTTP::Server::Context, _head : Bool) { context }
patterns = ["/app/static", "/app/:id", "/app/:account/nested/:id", "/files/*:rest", "/optional/?:id", "/space/a b"]
patterns.concat((0...64).map { |i| "/fanout/#{i}/:id" })
patterns << "/deep/#{(1..20).map { |i| ":p#{i}" }.join('/')}"
patterns.each do |path|
  handler.add_route("GET", path, {action, false})
  handler.add_route("HEAD", path, {action, true})
end
# Different methods on named siblings exercise snapshot method pruning.
100.times { |i| handler.add_route("METHOD#{i}", "/methods/:capture#{i}/end#{i}", {action, false}) }
if handler.responds_to?(:compile_routes)
  handler.compile_routes
end

measure_lookup("static", handler, "GET", "/app/static", {} of String => String)
measure_lookup("static alias", handler, "GET", "/app/static/", {} of String => String)
measure_lookup("dynamic", handler, "GET", "/app/7", {"id" => "7"})
measure_lookup("nested", handler, "GET", "/app/42/nested/7", {"account" => "42", "id" => "7"})
measure_lookup("fanout", handler, "GET", "/fanout/42/7", {"id" => "7"})
measure_lookup("glob", handler, "GET", "/files/a/b/c/d/e", {"rest" => "a/b/c/d/e"})
measure_lookup("optional absent", handler, "GET", "/optional", {} of String => String)
measure_lookup("optional present", handler, "GET", "/optional/7", {"id" => "7"})
measure_lookup("encoded capture", handler, "GET", "/app/a%2Fb", {"id" => "a/b"})
measure_lookup("encoded static", handler, "GET", "/space/a%20b", {} of String => String)
measure_lookup("early miss", handler, "GET", "/missing/path/with/several/segments", nil)
measure_lookup("late miss", handler, "GET", "/app/42/nested/7/missing", nil)
measure_lookup("HEAD", handler, "HEAD", "/app/7", {"id" => "7"})
measure_lookup("many captures", handler, "GET", "/deep/#{(1..20).join('/')}", (1..20).to_h { |i| {"p#{i}", i.to_s} })
measure_lookup("method backtracking", handler, "METHOD99", "/methods/value/end99", {"capture99" => "value"})
measure_lookup("method miss", handler, "ABSENT", "/methods/value/end99", nil)
