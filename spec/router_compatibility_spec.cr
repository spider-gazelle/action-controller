require "./spec_helper"

private def route_context(path : String, method = "GET")
  HTTP::Server::Context.new(
    HTTP::Request.new(method, path),
    HTTP::Server::Response.new(IO::Memory.new)
  )
end

private def route_action
  ->(context : HTTP::Server::Context, _head : Bool) { context }
end

private def marked_route(name : String)
  ->(context : HTTP::Server::Context, _head : Bool) {
    context.response.headers["X-Route"] = name
    context
  }
end

private class RouteCompatibilityRouter
  include ActionController::Router
end

describe ActionController::Router::RouteHandler do
  it "prefers an exact static route and accepts its trailing slash alias" do
    handler = ActionController::Router::RouteHandler.new
    static = {marked_route("static"), false}
    dynamic = {marked_route("dynamic"), false}
    handler.add_route("GET", "/items/:id", dynamic)
    handler.add_route("GET", "/items/new", static)

    ["/items/new", "/items/new/"].each do |path|
      context = route_context(path)
      matched = handler.search_route("GET", path, context)
      matched.should_not be_nil
      matched.try(&.[0].call(context, false))
      context.response.headers["X-Route"].should eq "static"
      context.route_params.should be_empty
    end

    context = route_context("/items/42")
    matched = handler.search_route("GET", "/items/42", context)
    matched.should_not be_nil
    matched.try(&.[0].call(context, false))
    context.response.headers["X-Route"].should eq "dynamic"
    context.route_params.should eq({"id" => "42"})
  end

  it "backs out of a static branch that fails deeper in the path" do
    handler = ActionController::Router::RouteHandler.new
    specific = {marked_route("specific"), false}
    fallback = {marked_route("fallback"), false}
    handler.add_route("GET", "/catalog/fixed/:id/extra", specific)
    handler.add_route("GET", "/catalog/:kind/:id", fallback)

    context = route_context("/catalog/fixed/123")
    matched = handler.search_route("GET", "/catalog/fixed/123", context)
    matched.should_not be_nil
    matched.try(&.[0].call(context, false))
    context.response.headers["X-Route"].should eq "fallback"
    context.route_params.should eq({"kind" => "fixed", "id" => "123"})
  end

  it "decodes captured segments after splitting the raw path" do
    handler = ActionController::Router::RouteHandler.new
    handler.add_route("GET", "/user/:id", {route_action, false})

    {"/user/a%20b" => "a b", "/user/a%2Fb" => "a/b"}.each do |path, expected|
      context = route_context(path)
      handler.search_route("GET", path, context).should_not be_nil
      context.route_params.should eq({"id" => expected})
    end
  end

  it "matches encoded static segments and more than sixteen captures" do
    handler = ActionController::Router::RouteHandler.new
    handler.add_route("GET", "/search/hello world", {route_action, false})
    encoded = route_context("/search/hello%20world")
    handler.search_route("GET", "/search/hello%20world", encoded).should_not be_nil

    names = (1..20).map { |index| ":p#{index}" }
    values = (1..20).map(&.to_s)
    pattern = "/many/#{names.join('/')}"
    path = "/many/#{values.join('/')}"
    handler.add_route("GET", pattern, {route_action, false})
    context = route_context(path)
    handler.search_route("GET", path, context).should_not be_nil
    context.route_params.should eq((1..20).to_h { |index| {"p#{index}", index.to_s} })
  end

  it "supports optional captures and named or unnamed globs" do
    optional = ActionController::Router::RouteHandler.new
    optional.add_route("GET", "/items/?:id", {route_action, false})
    without_id = route_context("/items")
    optional.search_route("GET", "/items", without_id).should_not be_nil
    without_id.route_params.should be_empty
    with_id = route_context("/items/7")
    optional.search_route("GET", "/items/7", with_id).should_not be_nil
    with_id.route_params.should eq({"id" => "7"})

    {"*" => "glob", "*:rest" => "rest"}.each do |pattern, name|
      handler = ActionController::Router::RouteHandler.new
      handler.add_route("GET", "/files/#{pattern}", {route_action, false})
      context = route_context("/files/a/b/c")
      handler.search_route("GET", "/files/a/b/c", context).should_not be_nil
      context.route_params.should eq({name => "a/b/c"})
    end
  end

  it "keeps method-specific payloads and the GET-derived HEAD flag" do
    router = RouteCompatibilityRouter.new
    router.get("/resource") { |context, _head| context }
    router.post("/resource") { |context, _head| context }

    get = route_context("/resource")
    head = route_context("/resource", "HEAD")
    post = route_context("/resource", "POST")
    router.route_handler.search_route("GET", "/resource", get).try(&.[1]).should be_false
    router.route_handler.search_route("HEAD", "/resource", head).try(&.[1]).should be_true
    router.route_handler.search_route("POST", "/resource", post).try(&.[1]).should be_false
    router.route_handler.search_route("DELETE", "/resource", route_context("/resource", "DELETE")).should be_nil
  end

  it "replaces existing route params for a dynamic hit but leaves them on a static hit" do
    handler = ActionController::Router::RouteHandler.new
    handler.add_route("GET", "/items/new", {route_action, false})
    handler.add_route("GET", "/items/:id", {route_action, false})
    context = route_context("/items/42")
    original = context.route_params
    original["sentinel"] = "original"

    handler.search_route("GET", "/items/42", context).should_not be_nil
    context.route_params.should eq({"id" => "42"})
    context.route_params.same?(original).should be_false

    handler.search_route("GET", "/items/new", context).should_not be_nil
    context.route_params.should eq({"id" => "42"})
  end

  it "matches a required capture after a multibyte static prefix" do
    handler = ActionController::Router::RouteHandler.new
    handler.add_route("GET", "/café/:name", {route_action, false})
    # Test the matcher directly: newer Crystal request validators reject raw
    # UTF-8 on an HTTP request line before the router sees it.
    context = route_context("/")
    handler.search_route("GET", "/café/naïve", context).should_not be_nil
    context.route_params.should eq({"name" => "naïve"})
  end
end
