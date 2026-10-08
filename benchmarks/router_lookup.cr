require "../src/action-controller"

def measure(name : String, matcher, path : String)
  20_000.times { matcher.match("GET", path) }
  samples = [] of Float64
  allocations = [] of Float64
  checksum = 0_u64
  11.times do
    GC.collect
    before = GC.stats.total_bytes
    start = Time.instant
    200_000.times do
      if match = matcher.match("GET", path)
        checksum &+= (match.payload + match.params.size).to_u64
      end
    end
    samples << (Time.instant - start).total_nanoseconds / 200_000
    allocations << (GC.stats.total_bytes - before).to_f / 200_000
  end
  puts({name: name, ns: samples.sort[5], bytes: allocations.sort[5], checksum: checksum}.to_json)
end

original = LuckyRouter::Matcher(Int32).new
optimized = ActionController::Router::Matcher(Int32).new
patterns = ["/single/:id", "/nested/:account/items/:id", "/files/*:rest", "/fixed/path"]
patterns.concat((0...64).map { |index| "/fanout/#{index}/:id" })
patterns << "/many/#{(1..20).map { |index| ":p#{index}" }.join('/')}"
patterns.each_with_index do |pattern, index|
  original.add("GET", pattern, index)
  optimized.add("GET", pattern, index)
end

paths = {
  "one capture"     => "/single/7",
  "two captures"    => "/nested/42/items/7",
  "fanout"          => "/fanout/42/7",
  "glob"            => "/files/a/b/c/d/e",
  "encoded capture" => "/single/a%2Fb",
  "early miss"      => "/missing/path/with/several/segments",
  "late miss"       => "/nested/42/items/7/missing",
  "twenty captures" => "/many/#{(1..20).join('/')}",
}
paths.each do |name, path|
  before = original.match("GET", path)
  after = optimized.match("GET", path)
  raise "different payload for #{path}" unless before.try(&.payload) == after.try(&.payload)
  raise "different captures for #{path}" unless before.try(&.params) == after.try(&.params)
  measure("original #{name}", original, path)
  measure("optimized #{name}", optimized, path)
end
