require "./spec_helper"

describe ActionController::Router::Matcher do
  it "matches the original trie across branch failures, methods, encoding, globs and deep paths" do
    original = LuckyRouter::Matcher(Int32).new
    optimized = ActionController::Router::Matcher(Int32).new
    patterns = [
      "/", "/plain", "/catalog/fixed/:id/extra", "/catalog/:kind/:id",
      "/files/*:rest", "/bare/*", "/docs/:id/info", "/docs/:slug/data",
      "/items/?:id", "/optional/?:left/fixed/?:right", "/café/:name",
      "/a//:id", "//:id", "/escaped space/:id",
    ]
    patterns.concat((0...32).map { |index| "/fanout/#{index}/:id" })
    patterns << "/many/#{(1..20).map { |index| ":p#{index}" }.join('/')}"
    patterns << "/deep/#{(1..80).map { |index| ":p#{index}" }.join('/')}"
    patterns.each_with_index do |pattern, index|
      {"GET", "POST", "HEAD"}.each do |method|
        original.add(method, pattern, index)
        optimized.add(method, pattern, index)
      end
    end
    paths = [
      "", "/", "//", "/plain", "/plain/", "/plain//", "/missing",
      "/catalog/fixed/7/extra", "/catalog/fixed/7", "/catalog/x/7",
      "/files", "/files/", "/files/a", "/files/a/", "/files/a//",
      "/files//", "/files///", "/files/a//b/", "/bare/a/b/c",
      "/files/a%2Fb/", "/files/a%20b/c", "/docs/7/data", "/docs/7/info",
      "/items", "/items/7", "/optional/fixed", "/optional/fixed/7",
      "/optional/fixed/7/9", "/café/naïve", "/caf%C3%A9/na%C3%AFve",
      "/a//7", "//7", "/escaped%20space/7",
    ]
    paths.concat((0...32).map { |index| "/fanout/#{index}/7" })
    paths << "/many/#{(1..20).join('/')}"
    paths << "/deep/#{(1..80).join('/')}"
    random = Random.new(13)
    tokens = ["catalog", "fixed", "extra", "files", "7", "a%20b", "a%2Fb", "", "naïve"]
    500.times do
      paths << "/#{Array.new(random.rand(1..8)) { tokens.sample(random) }.join('/')}"
    end
    paths.each do |path|
      {"GET", "POST", "HEAD", "head", "DELETE", "UNKNOWN"}.each do |method|
        expected = original.match(method, path)
        actual = optimized.match(method, path)
        actual.try(&.payload).should eq(expected.try(&.payload)), "payload differs for #{method} #{path}"
        actual.try(&.params).should eq(expected.try(&.params)), "captures differ for #{method} #{path}"
      end
    end
  end

  it "preserves captures from the successful dynamic branch after a method mismatch" do
    original = LuckyRouter::Matcher(String).new
    optimized = ActionController::Router::Matcher(String).new
    {original, optimized}.each do |matcher|
      matcher.add("POST", "/docs/fixed/:id", "post")
      matcher.add("POST", "/docs/:first/details", "first")
      matcher.add("GET", "/docs/:second/:id", "get")
    end
    expected = original.match("GET", "/docs/fixed/details").should_not be_nil
    actual = optimized.match("GET", "/docs/fixed/details").should_not be_nil
    actual.payload.should eq expected.payload
    actual.params.should eq({"id" => "details", "second" => "fixed"})
  end
end
