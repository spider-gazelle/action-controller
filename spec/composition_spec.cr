require "./spec_helper"
require "../src/action-controller/server"
require "../src/action-controller/mcp"

module ComposableFirst
  abstract class Base < AC::Base
  end

  class Pages < Base
    base "/composition/first"

    before_action :mark

    def mark
      response.headers["X-App"] = "first"
    end

    @[AC::Route::GET("/")]
    def index : String
      "first"
    end

    @[AC::Route::GET("/missing")]
    def missing
      render :not_found, text: "deliberate"
    end
  end
end

module ComposableSecond
  abstract class Base < AC::Base
  end

  class Pages < Base
    base "/composition/second"

    @[AC::Route::GET("/")]
    def index : String
      "second"
    end
  end
end

private class CompositionFallback
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    context.response.print "fallback"
  end
end

@[AC::MCP(endpoint: true, hide: false)]
class CompositionOAuth < AC::Base
  base "/composition/oauth"

  @[AC::Route::GET("/token")]
  def token : String
    request.path
  end

  @[AC::Route::GET("/redirect")]
  def redirect
    redirect_to route_path(:token)
  end

  @[AC::MCP(prompt: true)]
  def explain : String
    "OAuth at #{base_route}"
  end

  def instructions : String
    "Use OAuth at #{base_route}"
  end

  @[AC::Route::WebSocket("/socket")]
  def socket(socket)
    socket.on_message { |message| socket.send(message) }
  end
end

class CompositionHost < AC::Base
  base "/composition/host/"
  mount "/auth/", CompositionOAuth
  mount "/backup/", CompositionOAuth
end

class CompositionOuter < AC::Base
  base "/composition/outer"
  mount "/inner/", CompositionHost
end

class CompositionAccountHost < AC::Base
  base "/composition/accounts/:account_id"
  mount "/auth", CompositionOAuth
end

module CompositionInherited
  abstract class Base < AC::Base
    @[AC::Route::GET("/")]
    def index : String
      "inherited"
    end
  end

  class Pages < Base
    base "/composition/inherited"
  end
end

class CompositionBound < AC::Base
  base "/composition/bound/:id"

  @[AC::Route::GET("/")]
  def index(id : String) : String
    id
  end
end

@[AC::MCP(endpoint: true, hide: false)]
class CompositionTyped < AC::Base
  base "/composition/typed"

  @[AC::Route::GET("/")]
  def show(tenant_id : Int64) : Int64
    tenant_id
  end

  @[AC::Route::GET("/redirect")]
  def redirect(tenant_id : Int64)
    redirect_to route_path(:show, tenant_id: tenant_id + 1)
  end

  @[AC::MCP(prompt: true)]
  def describe_tenant(tenant_id : Int64) : String
    "Tenant #{tenant_id}"
  end
end

class CompositionTypedHost < AC::Base
  base "/composition/typed-host/:tenant_id"
  mount "/auth", CompositionTyped
end

class CompositionOptionalTypedHost < AC::Base
  base "/composition/optional-typed/?:tenant_id"
  mount "/auth", CompositionTyped
end

@[AC::MCP(endpoint: true, hide: false)]
class CompositionOptionalSource < AC::Base
  base "/composition/optional-source/?:label"

  @[AC::Route::GET("/")]
  def index(label : String? = nil) : String
    label || "none"
  end

  @[AC::MCP(prompt: true)]
  def explain(label : String? = nil) : String
    label || "none"
  end

  @[AC::Route::GET("/plain")]
  def plain : String
    "plain"
  end

  @[AC::MCP(prompt: true)]
  def plain_prompt : String
    "plain"
  end
end

class CompositionOptionalSourceHost < AC::Base
  base "/composition/optional-source-host"
  mount "/app", CompositionOptionalSource
end

class CompositionOptionalHost < AC::Base
  base "/composition/optional/?:tenant_id"
  mount "/auth", CompositionOAuth
end

class CompositionFiltered < AC::Base
  base "/composition/filtered"

  @[AC::Route::Filter(:before_action)]
  def account(tenant_id : Int64)
    response.headers["X-Tenant"] = tenant_id.to_s
  end

  @[AC::Route::GET("/")]
  def index : String
    "filtered"
  end
end

class CompositionFilteredHost < AC::Base
  base "/composition/filtered-host/:tenant_id"
  mount "/auth", CompositionFiltered
end

class CompositionOptionalFilteredHost < AC::Base
  base "/composition/optional-filtered/?:tenant_id"
  mount "/auth", CompositionFiltered
end

module CompositionInheritedEndpoint
  @[AC::MCP(endpoint: true, hide: false)]
  abstract class Base < AC::Base
    base "/composition/inherited-original"

    @[AC::Route::GET("/token")]
    def token : String
      request.path
    end

    @[AC::MCP(prompt: true)]
    def explain : String
      base_route
    end

    def instructions : String
      "Inherited at #{base_route}"
    end
  end

  class Pages < Base
    base "/composition/inherited-endpoint"
  end
end

module CompositionLibrary
  abstract class Base < AC::Base
    base "/composition/library"

    @[AC::Route::Filter(:before_action)]
    def mark_library
      response.headers["X-Library"] = "library"
    end
  end

  @[AC::MCP(endpoint: true, hide: false)]
  class Pages < Base
    base "/composition/library/pages"

    @[AC::Route::GET("/")]
    def index : String
      request.path
    end

    @[AC::MCP(prompt: true)]
    def explain : String
      base_route
    end

    def instructions : String
      "Library at #{base_route}"
    end
  end

  class External < Base
    base "/composition/outside-library"

    @[AC::Route::GET("/")]
    def index : String
      request.path
    end
  end
end

class CompositionLibraryHost < AC::Base
  base "/composition/library-host"
  mount "/app", CompositionLibrary::Base
end

class CompositionLibraryBorrower < AC::Base
  base "/composition/library-borrower"
  mount "/page", CompositionLibrary::Pages
end

module CompositionOwnedMount
  abstract class Base < AC::Base
    base "/composition/owned-mount"
    mount "/auth", Auth
  end

  class Auth < Base
    base "/composition/owned-mount/original"

    @[AC::Route::GET("/token")]
    def token : String
      request.path
    end
  end
end

class CompositionCycleA < AC::Base
  mount "/b", CompositionCycleB
  mount "/conflicts", CompositionConflicts::Base
end

class CompositionCycleB < AC::Base
  mount "/a", CompositionCycleA
end

module CompositionConflicts
  abstract class Base < AC::Base
  end

  class First < Base
    base "/composition/conflict"
    @[AC::Route::GET("/:id")]
    def show(id : String) : String
      id
    end
  end

  class Second < Base
    base "/composition/conflict"
    @[AC::Route::GET("/:name")]
    def show(name : String) : String
      name
    end
  end
end

describe AC::Composition do
  it "serves only descendants of an abstract application base" do
    handler = ComposableFirst::Base.handler
    client = HotTopic.new(handler)
    client.get("/composition/first").body.should eq %q("first")
    client.get("/composition/second").status_code.should eq 404
    handler.routes.map(&.[0]).uniq!.should eq ["ComposableFirst::Pages"]
  end

  it "passes route misses through independent handlers" do
    first = ComposableFirst::Base.handler
    second = ComposableSecond::Base.handler
    first.next = second
    second.next = CompositionFallback.new
    client = HotTopic.new(first)
    client.get("/composition/second").body.should eq %q("second")
    client.get("/unknown").body.should eq "fallback"
    client.get("/composition/second").headers.has_key?("X-App").should be_false
  end

  it "keeps responses from matched actions even when they return 404" do
    handler = ComposableFirst::Base.handler
    handler.next = CompositionFallback.new
    response = HotTopic.new(handler).get("/composition/first/missing")
    response.status_code.should eq 404
    response.body.should eq "deliberate"
    response.headers["X-App"].should eq "first"
  end

  it "constructs independent routers and handler chains" do
    first = ComposableFirst::Base.handler
    second = ComposableFirst::Base.handler
    first.next = CompositionFallback.new
    second.next.should be_nil
    first.route_handler.should_not be second.route_handler
    HotTopic.new(first.handler).get("/unknown").status_code.should eq 404
  end

  it "supports HTTP::Server's normal handler typing" do
    handlers = [ComposableFirst::Base.handler, CompositionFallback.new] of HTTP::Handler
    server = HTTP::Server.new(handlers)
    server.close
  end

  it "shares explicit selection with the server and spec helper" do
    previous = AC::Composition.default
    begin
      composition = AC::Composition.new([ComposableFirst::Base.name, ComposableSecond::Base.name])
      AC::Composition.default = composition
      AC::Server.routes.map(&.[0]).should eq ["ComposableFirst::Pages", "ComposableFirst::Pages", "ComposableSecond::Pages"]
      server = AC::Server.new(composition: composition)
      server.composition.should be composition
      server.route_handler.should_not be composition.route_handler
      AC::SpecHelper.new(composition).hot_topic.get("/composition/second").status_code.should eq 200
      AC::SpecHelper.new(composition).hot_topic.get("/hello").status_code.should eq 404
      server.close
    ensure
      AC::Composition.default = previous
    end
  end

  it "mounts replacement bases repeatedly without exposing the original path" do
    client = HotTopic.new(CompositionHost.handler)
    client.get("/composition/host/auth/token").body.should eq %q("/composition/host/auth/token")
    client.get("/composition/host/backup/token").status_code.should eq 200
    client.get("/composition/oauth/token").status_code.should eq 404
    CompositionOAuth.token.should eq "/composition/oauth/token"
    client.get("/composition/host/auth/redirect").headers["Location"].should eq "/composition/host/auth/token"
  end

  it "expands nested mounts and passes their route misses downstream" do
    handler = CompositionOuter.handler
    handler.next = CompositionFallback.new
    client = HotTopic.new(handler)
    client.get("/composition/outer/inner/auth/token").status_code.should eq 200
    client.get("/composition/outer/inner/auth/missing").body.should eq "fallback"
  end

  it "rejects cycles and equivalent parameterized public routes" do
    expect_raises(ArgumentError, /mount cycle/) { CompositionCycleA.handler }
    expect_raises(ArgumentError, /conflicting route GET/) { CompositionConflicts::Base.handler }
    expect_raises(ArgumentError, /unknown application root/) { AC::Composition.new(["MissingApplication"]) }
  end

  it "binds parameterized mounts and builds public URLs outside a request" do
    composition = CompositionAccountHost.handler
    client = HotTopic.new(composition)
    client.get("/composition/accounts/42/auth/token").status_code.should eq 200
    client.get("/composition/accounts/42/auth/redirect").headers["Location"].should eq "/composition/accounts/42/auth/token"
    composition.url_for(CompositionOAuth, :token, account_id: 42).should eq "/composition/accounts/42/auth/token"
    repeated = CompositionHost.handler
    expect_raises(AC::InvalidRoute, /mount_base/) { repeated.url_for(CompositionOAuth, :token) }
    repeated.url_for(CompositionOAuth, :token, mount_base: "/composition/host/backup").should eq "/composition/host/backup/token"
  end

  it "generates unified OpenAPI using effective public paths and unique operations" do
    composition = CompositionHost.handler
    doc = AC::OpenAPI.generate_open_api_docs({} of String => AC::OpenAPI::KlassDoc, "test", "1", composition: composition)
    doc[:paths].keys.sort!.should eq ["/composition/host/auth/redirect", "/composition/host/auth/socket", "/composition/host/auth/token", "/composition/host/backup/redirect", "/composition/host/backup/socket", "/composition/host/backup/token"]
    ids = doc[:paths].values.compact_map(&.get.try(&.operation_id))
    ids.uniq.size.should eq ids.size
    account = AC::OpenAPI.generate_open_api_docs({} of String => AC::OpenAPI::KlassDoc, "test", "1", composition: CompositionAccountHost.handler)
    operation = account[:paths]["/composition/accounts/{account_id}/auth/token"].get.should_not be_nil
    param = (operation.parameters.should_not be_nil).first
    param.name.should eq "account_id"
    param.in.should eq "path"
    param.required.should be_true
  end

  it "exposes repeated MCP tools, prompts and relocated controller endpoints" do
    composition = CompositionHost.handler
    description = AC::MCPServer.generate_description(docs: false, composition: composition)
    description.toolboxes.size.should eq 2
    description.toolboxes.map(&.name).uniq!.size.should eq 2
    tools = description.toolboxes.flat_map(&.tools)
    tools.map(&.name).uniq!.size.should eq tools.size
    tools.select(&.path.ends_with?("/token")).map(&.path).sort!.should eq ["/composition/host/auth/token", "/composition/host/backup/token"]
    description.endpoints.map(&.path).sort!.should eq ["/composition/host/auth/mcp", "/composition/host/backup/mcp"]
    prompts = description.toolboxes.flat_map(&.prompts)
    prompts.size.should eq 2
    invoker = AC::MCPServer::Invoker.new(composition.route_handler, AC::MCPServer::PromptRouter.new(composition).route_handler)
    request = HTTP::Request.new("POST", "/mcp")
    result = JSON.parse(invoker.call(tools.find!(&.path.==("/composition/host/auth/token")), {} of String => JSON::Any, request))
    result.to_json.should contain "/composition/host/auth/token"
    instructions_path = description.endpoints.first.instructions_path.should_not be_nil
    invoker.instructions(instructions_path, request, {} of String => String).should contain "Use OAuth at /composition/host/"
    composition.routes.none?(&.[3].includes?("__mcp_prompt__")).should be_true
    invoker.get_prompt(prompts.first, {} of String => JSON::Any, request).should contain "OAuth at /composition/host/"
  end

  it "keeps inherited route metadata aligned with concrete controller dispatch" do
    composition = CompositionInherited::Base.handler
    HotTopic.new(composition).get("/composition/inherited").body.should eq %q("inherited")
    doc = AC::OpenAPI.generate_open_api_docs({} of String => AC::OpenAPI::KlassDoc, "test", "1", composition: composition)
    doc[:paths].keys.should eq ["/composition/inherited"]
    description = AC::MCPServer.generate_description(docs: false, composition: composition)
    description.toolboxes.flat_map(&.tools).map(&.path).should eq ["/composition/inherited"]
  end

  it "scopes cached descriptions to each composition" do
    path = File.tempname("composition-mcp", ".yml")
    previous = AC::MCPServer.description_path
    begin
      AC::MCPServer.description_path = path
      first = ComposableFirst::Base.handler
      second = ComposableSecond::Base.handler
      File.write(path, AC::MCPServer.generate_description(docs: false, composition: first).to_yaml)
      first_description = AC::MCPServer.description(first)
      second_description = AC::MCPServer.description(second)
      first_description.composition_id.should eq first.signature
      second_description.composition_id.should eq second.signature
      second_description.toolboxes.flat_map(&.tools).map(&.path).should eq ["/composition/second"]
      AC::MCPServer.description(first).should be first_description
    ensure
      AC::MCPServer.description_path = previous
      File.delete(path) if File.exists?(path)
      AC::MCPServer.description = nil
    end
  end

  it "serves a global MCP endpoint using the mounted app's composition" do
    composition = CompositionAccountHost.handler
    AC::MCPServer.mount(composition)
    client = HotTopic.new(composition)
    headers = HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json, text/event-stream"}
    initialize = client.post("/mcp", headers: headers, body: {jsonrpc: "2.0", id: 1, method: "initialize", params: {protocolVersion: "2025-11-25"}}.to_json)
    initialize.status_code.should eq 200
    headers["Mcp-Session-Id"] = initialize.headers["Mcp-Session-Id"]
    catalog = AC::MCPServer.description(composition)
    box = catalog.toolboxes.first
    client.post("/mcp", headers: headers, body: {jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: "open_toolbox", arguments: {name: box.name}}}.to_json).status_code.should eq 200
    tool = box.tools.find!(&.path.ends_with?("/token"))
    response = client.post("/mcp", headers: headers, body: {jsonrpc: "2.0", id: 3, method: "tools/call", params: {name: tool.name, arguments: {account_id: "42"}}}.to_json)
    response.status_code.should eq 200
    JSON.parse(response.body)["result"].to_json.should contain "/composition/accounts/42/auth/token"
    endpoint = client.post("/composition/accounts/42/auth/mcp", headers: HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json, text/event-stream"}, body: {jsonrpc: "2.0", id: 4, method: "initialize", params: {protocolVersion: "2025-11-25"}}.to_json)
    endpoint.status_code.should eq 200
    JSON.parse(endpoint.body)["result"]["instructions"].as_s.should contain "/composition/accounts/:account_id/auth"
  end

  it "preserves mounted HEAD and WebSocket handling" do
    composition = CompositionHost.handler
    client = AC::SpecHelper.new(composition).hot_topic
    client.head("/composition/host/auth/token").body.should be_empty
    socket = client.establish_ws("/composition/host/auth/socket")
    done = Channel(String | Exception).new(1)
    spawn do
      socket.on_message do |message|
        socket.close
        done.send(message)
      end
      socket.send("echo")
      socket.run
    rescue error
      done.send(error)
    end
    select
    when result = done.receive
      raise result if result.is_a?(Exception)
      result.should eq "echo"
    when timeout(5.seconds)
      fail "mounted WebSocket timed out"
    end
  ensure
    socket.try(&.close)
  end

  it "rejects MCP endpoints that compete with application routes" do
    composition = ComposableFirst::Base.handler
    expect_raises(ArgumentError, /conflicting MCP endpoint GET/) do
      AC::MCPServer.mount(composition, "/composition/first", endpoints: false)
    end
    HotTopic.new(composition).get("/composition/first").body.should eq %q("first")
  end

  it "rejects placements with removed or duplicate required path parameters" do
    controller = AC::Composition.controllers.find!(&.name.==(CompositionBound.name))
    expect_raises(ArgumentError, /removes required path parameters id/) do
      AC::Composition.new([AC::Composition::Placement.new(controller, "/bad")], true)
    end
    expect_raises(ArgumentError, /ambiguous path parameters/) do
      AC::Composition.new([AC::Composition::Placement.new(controller, "/bad/:id/:id")], true)
    end
    expect_raises(ArgumentError, /removes required path parameters id/) do
      AC::Composition.new([AC::Composition::Placement.new(controller, "/bad/?:id")], true)
    end
  end

  it "allows route_path arguments to override parameters bound by the mount" do
    client = HotTopic.new(CompositionTypedHost.handler)
    client.get("/composition/typed-host/42/auth/redirect").headers["Location"].should eq "/composition/typed-host/43/auth"
  end

  it "relocates typed query parameters into the mounted path" do
    composition = CompositionTypedHost.handler
    docs = AC::OpenAPI.generate_open_api_docs({} of String => AC::OpenAPI::KlassDoc, "test", "1", composition: composition)
    operation = docs[:paths]["/composition/typed-host/{tenant_id}/auth"].get.should_not be_nil
    parameters = operation.parameters.should_not be_nil
    parameters.size.should eq 1
    parameter = parameters.first
    parameter.in.should eq "path"
    parameter.required.should be_true
    (parameter.schema.should_not be_nil)["type"].as_s.should eq "integer"
    description = AC::MCPServer.generate_description(docs: false, composition: composition)
    prompt = description.toolboxes.first.prompts.first
    prompt.arguments.size.should eq 1
    prompt.arguments.first.in.should eq "path"
    endpoint = description.endpoints.first
    endpoint.toolbox.prompts.first.arguments.should be_empty
    invoker = AC::MCPServer::Invoker.new(composition.route_handler, AC::MCPServer::PromptRouter.new(composition).route_handler)
    invoker.get_prompt(endpoint.toolbox.prompts.first, {} of String => JSON::Any, HTTP::Request.new("POST", "/mcp"), {"tenant_id" => "42"}).should contain "Tenant 42"
  end

  it "builds optional and glob paths with encoded parameter overrides" do
    AC::Support.build_route("/root/?:id/detail/*:rest", id: "a/b", rest: "one two/file").should eq "/root/a%2Fb/detail/one%20two/file"
    AC::Support.build_route("/root/?:id/detail/*:rest").should eq "/root/detail"
    parts = {"id" => "old", :page => 1} of (String | Symbol) => (Bool | Int32 | Int64 | Float32 | Float64 | String | Symbol)?
    AC::Support.build_route("/root/:id", parts, id: "new", page: 2).should eq "/root/new?page=2"
    expect_raises(AC::InvalidRoute, /optional route parameter/) do
      AC::Support.build_route("/root/?:id/detail/*:rest", rest: "file")
    end
  end

  it "keeps optional mount parameters aligned across HTTP, OpenAPI and MCP" do
    composition = CompositionOptionalHost.handler
    client = HotTopic.new(composition)
    client.get("/composition/optional/auth/redirect").headers["Location"].should eq "/composition/optional/auth/token"
    client.get("/composition/optional/42/auth/redirect").headers["Location"].should eq "/composition/optional/42/auth/token"
    docs = AC::OpenAPI.generate_open_api_docs({} of String => AC::OpenAPI::KlassDoc, "test", "1", composition: composition)
    docs[:paths].has_key?("/composition/optional/auth/token").should be_true
    docs[:paths].has_key?("/composition/optional/{tenant_id}/auth/token").should be_true
    description = AC::MCPServer.generate_description(docs: false, composition: composition)
    prompt = description.toolboxes.first.prompts.first
    prompt.arguments.first.required?.should be_false
    invoker = AC::MCPServer::Invoker.new(composition.route_handler, AC::MCPServer::PromptRouter.new(composition).route_handler)
    invoker.get_prompt(prompt, {} of String => JSON::Any, HTTP::Request.new("POST", "/mcp")).to_json.should contain "/composition/optional/?:tenant_id/auth"
    endpoint = description.endpoints.first
    endpoint.bound.should eq ["tenant_id"]
    endpoint.toolbox.prompts.first.arguments.map(&.name).should eq ["tenant_id"]
    transports = AC::MCPServer.mount_endpoints(composition)
    transport = transports.first
    headers = HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json, text/event-stream"}
    body = {jsonrpc: "2.0", id: 1, method: "initialize", params: {protocolVersion: "2025-11-25"}}.to_json
    omitted = client.post("/composition/optional/auth/mcp", headers: headers, body: body)
    included = client.post("/composition/optional/42/auth/mcp", headers: headers, body: body)
    omitted_session = transport.sessions[omitted.headers["Mcp-Session-Id"]]?.should_not be_nil
    included_session = transport.sessions[included.headers["Mcp-Session-Id"]]?.should_not be_nil
    omitted_session.bound.should be_empty
    included_session.bound.should eq({"tenant_id" => "42"})
  end

  it "relocates inherited tools, prompts and MCP instructions to the subclass base" do
    composition = CompositionInheritedEndpoint::Base.handler
    AC::MCPServer.endpoint_paths(composition).should eq ["/composition/inherited-endpoint/mcp"]
    description = AC::MCPServer.generate_description(docs: false, composition: composition)
    endpoint = description.endpoints.first
    endpoint.path.should eq "/composition/inherited-endpoint/mcp"
    description.toolboxes.first.tools.first.path.should eq "/composition/inherited-endpoint/token"
    endpoint.toolbox.prompts.size.should eq 1
    invoker = AC::MCPServer::Invoker.new(composition.route_handler, AC::MCPServer::PromptRouter.new(composition).route_handler)
    instructions = endpoint.instructions_path.should_not be_nil
    invoker.instructions(instructions, HTTP::Request.new("POST", "/mcp"), {} of String => String).should eq "Inherited at /composition/inherited-endpoint"
  end

  it "uses the spec helper's selected composition for MCP discovery" do
    helper = AC::SpecHelper.new(ComposableFirst::Base.handler)
    transport = AC::MCPServer.mount(helper, endpoints: false)
    response = transport.protocol.handle("tools/call", JSON.parse(%({"name":"list_toolboxes"})).as_h, AC::MCPServer::Session.new("2025-11-25"), HTTP::Request.new("POST", "/mcp"), [] of String)
    result = JSON.parse(response)["structuredContent"]["toolboxes"].as_a
    result.size.should eq 1
    result.first["name"].as_s.should eq "pages"
  end

  it "preserves filter parameter schemas when a mount binds them in the path" do
    composition = CompositionFilteredHost.handler
    HotTopic.new(composition).get("/composition/filtered-host/42/auth").headers["X-Tenant"].should eq "42"
    docs = AC::OpenAPI.generate_open_api_docs({} of String => AC::OpenAPI::KlassDoc, "test", "1", composition: composition)
    operation = docs[:paths]["/composition/filtered-host/{tenant_id}/auth"].get.should_not be_nil
    parameters = operation.parameters.should_not be_nil
    parameters.size.should eq 1
    parameters.first.in.should eq "path"
    schema = parameters.first.schema.should_not be_nil
    schema["type"].as_s.should eq "integer"
  end

  it "rejects MCP endpoints that overwrite manually registered routes or earlier mounts" do
    composition = ComposableFirst::Base.handler
    composition.get("/custom-mcp/:id") do |context, _head|
      context.response.print "custom"
      context
    end
    expect_raises(ArgumentError, /conflicting MCP endpoint/) { AC::MCPServer.mount(composition, "/custom-mcp/:name", endpoints: false) }
    HotTopic.new(composition).get("/custom-mcp/42").body.should eq "custom"
    HotTopic.new(composition).post("/custom-mcp/42").status_code.should eq 404
    AC::MCPServer.mount(composition, endpoints: false)
    expect_raises(ArgumentError, /conflicting MCP endpoint/) { AC::MCPServer.mount(composition, endpoints: false) }
  end

  it "keeps an explicitly selected subtree independent of mounts in other applications" do
    composition = CompositionLibrary::Base.handler
    composition.routes.map(&.[3]).sort!.should eq ["/composition/library/pages", "/composition/outside-library"]
    HotTopic.new(composition).get("/composition/library/pages").status_code.should eq 200
    docs = AC::OpenAPI.generate_open_api_docs({} of String => AC::OpenAPI::KlassDoc, "test", "1", composition: composition)
    docs[:paths].keys.sort!.should eq ["/composition/library/pages", "/composition/outside-library"]
    description = AC::MCPServer.generate_description(docs: false, composition: composition)
    description.toolboxes.flat_map(&.tools).map(&.path).sort!.should eq docs[:paths].keys.sort!
    description.endpoints.map(&.path).should eq ["/composition/library/pages/mcp"]
  end

  it "mounts a complete application subtree using paths relative to its root" do
    composition = CompositionLibraryHost.handler
    client = HotTopic.new(composition)
    pages = client.get("/composition/library-host/app/pages")
    pages.body.should eq %q("/composition/library-host/app/pages")
    pages.headers["X-Library"].should eq "library"
    client.get("/composition/library-host/app/composition/outside-library").status_code.should eq 200
    client.get("/composition/library/pages").status_code.should eq 404
    description = AC::MCPServer.generate_description(docs: false, composition: composition)
    endpoint = description.endpoints.first
    endpoint.path.should eq "/composition/library-host/app/pages/mcp"
    invoker = AC::MCPServer::Invoker.new(composition.route_handler, AC::MCPServer::PromptRouter.new(composition).route_handler)
    prompt = endpoint.toolbox.prompts.first
    request = HTTP::Request.new("POST", "/mcp")
    invoker.get_prompt(prompt, {} of String => JSON::Any, request).should contain "/composition/library-host/app/pages"
    instructions = endpoint.instructions_path.should_not be_nil
    invoker.instructions(instructions, request, {} of String => String).should eq "Library at /composition/library-host/app/pages"
  end

  it "unifies independently selected and mounted instances of an application" do
    composition = AC::Composition.new([CompositionLibrary::Base.name, CompositionLibraryHost.name])
    docs = AC::OpenAPI.generate_open_api_docs({} of String => AC::OpenAPI::KlassDoc, "test", "1", composition: composition)
    docs[:paths].keys.sort!.should eq ["/composition/library-host/app/composition/outside-library", "/composition/library-host/app/pages", "/composition/library/pages", "/composition/outside-library"]
    ids = docs[:paths].values.compact_map(&.get.try(&.operation_id))
    ids.uniq.size.should eq ids.size
    description = AC::MCPServer.generate_description(docs: false, composition: composition)
    tools = description.toolboxes.flat_map(&.tools)
    tools.map(&.path).sort!.should eq docs[:paths].keys.sort!
    tools.map(&.name).uniq!.size.should eq tools.size
    description.endpoints.map(&.path).sort!.should eq ["/composition/library-host/app/pages/mcp", "/composition/library/pages/mcp"]
    automatic = AC::Composition.new
    automatic.routes.none? { |route| route[3] == "/composition/library/pages" || route[3] == "/composition/outside-library" }.should be_true
    automatic.routes.select(&.[0].==(CompositionLibrary::Pages.name)).map(&.[3]).sort!.should eq ["/composition/library-borrower/page", "/composition/library-host/app/pages"]
  end

  it "still relocates a descendant mounted by the selected application's own base" do
    composition = CompositionOwnedMount::Base.handler
    composition.routes.map(&.[3]).should eq ["/composition/owned-mount/auth/token"]
    client = HotTopic.new(composition)
    client.get("/composition/owned-mount/auth/token").body.should eq %q("/composition/owned-mount/auth/token")
    client.get("/composition/owned-mount/original/token").status_code.should eq 404
    description = AC::MCPServer.generate_description(docs: false, composition: composition)
    description.toolboxes.flat_map(&.tools).map(&.path).should eq ["/composition/owned-mount/auth/token"]
  end

  it "preserves required action arguments in optional mount catalogs" do
    composition = CompositionOptionalTypedHost.handler
    client = HotTopic.new(composition)
    client.get("/composition/optional-typed/auth?tenant_id=42").body.should eq "42"
    client.get("/composition/optional-typed/42/auth").body.should eq "42"
    docs = AC::OpenAPI.generate_open_api_docs({} of String => AC::OpenAPI::KlassDoc, "test", "1", composition: composition)
    operation = docs[:paths]["/composition/optional-typed/auth"].get.should_not be_nil
    params = operation.parameters.should_not be_nil
    params.size.should eq 1
    params.first.in.should eq "query"
    params.first.required.should be_true
    operation.to_json.should_not contain "query_fallback"
    description = AC::MCPServer.generate_description(docs: false, composition: composition)
    box = description.toolboxes.first
    tool = box.tools.find!(&.path.ends_with?("/auth"))
    tool.input_schema["required"].as_a.map(&.as_s).should eq ["tenant_id"]
    box.prompts.first.arguments.first.required?.should be_true
  end

  it "keeps optional parameters usable as queries when a mount removes their original path" do
    composition = CompositionOptionalSourceHost.handler
    HotTopic.new(composition).get("/composition/optional-source-host/app?label=provided").body.should eq %q("provided")
    docs = AC::OpenAPI.generate_open_api_docs({} of String => AC::OpenAPI::KlassDoc, "test", "1", composition: composition)
    operation = docs[:paths]["/composition/optional-source-host/app"].get.should_not be_nil
    params = operation.parameters.should_not be_nil
    params.map(&.name).should eq ["label"]
    params.first.in.should eq "query"
    description = AC::MCPServer.generate_description(docs: false, composition: composition)
    prompt = description.toolboxes.first.prompts.first
    prompt.arguments.first.in.should eq "query"
    invoker = AC::MCPServer::Invoker.new(composition.route_handler, AC::MCPServer::PromptRouter.new(composition).route_handler)
    invoker.get_prompt(prompt, {"label" => JSON::Any.new("provided")}, HTTP::Request.new("POST", "/mcp")).should contain "provided"
    plain = description.toolboxes.first.prompts.find!(&.path.ends_with?("/plain_prompt"))
    plain.arguments.should be_empty
    plain_operation = docs[:paths]["/composition/optional-source-host/app/plain"].get.should_not be_nil
    (plain_operation.parameters.should_not be_nil).should be_empty
  end

  it "describes optional endpoint arguments according to the session's bound URL values" do
    composition = CompositionOptionalTypedHost.handler
    transport = AC::MCPServer.mount_endpoints(composition).first
    request = HTTP::Request.new("POST", "/mcp")
    unbound = AC::MCPServer::Session.new("2025-11-25")
    bound = AC::MCPServer::Session.new("2025-11-25", {"tenant_id" => "42"})
    protocol = transport.protocol
    tools = JSON.parse(protocol.handle("tools/list", {} of String => JSON::Any, unbound, request, [] of String))["tools"].as_a
    tool = tools.find!(&.["name"].==("show"))
    tool["inputSchema"]["required"].as_a.map(&.as_s).should eq ["tenant_id"]
    bound_tools = JSON.parse(protocol.handle("tools/list", {} of String => JSON::Any, bound, request, [] of String))["tools"].as_a
    bound_tools.find!(&.["name"].==("show"))["inputSchema"]["properties"].as_h.should be_empty
    prompts = JSON.parse(protocol.handle("prompts/list", {} of String => JSON::Any, unbound, request, [] of String))["prompts"].as_a
    prompts.first["arguments"].as_a.first["required"].as_bool.should be_true
    bound_prompts = JSON.parse(protocol.handle("prompts/list", {} of String => JSON::Any, bound, request, [] of String))["prompts"].as_a
    bound_prompts.first["arguments"].as_a.should be_empty
    call = JSON.parse(%({"name":"show","arguments":{"tenant_id":43}})).as_h
    JSON.parse(protocol.handle("tools/call", call, unbound, request, [] of String))["isError"].as_bool.should be_false
    call = JSON.parse(%({"name":"show","arguments":{}})).as_h
    JSON.parse(protocol.handle("tools/call", call, bound, request, [] of String))["isError"].as_bool.should be_false
    call = JSON.parse(%({"name":"show","arguments":{"tenant_id":99}})).as_h
    result = JSON.parse(protocol.handle("tools/call", call, bound, request, [] of String))
    JSON.parse(result["content"].as_a.first["text"].as_s)["body"].as_i.should eq 42
    prompt_call = JSON.parse(%({"name":"describe_tenant","arguments":{}})).as_h
    protocol.handle("prompts/get", prompt_call, bound, request, [] of String).should contain "Tenant 42"
    repeated = JSON.parse(protocol.handle("tools/list", {} of String => JSON::Any, unbound, request, [] of String))["tools"].as_a
    repeated.find!(&.["name"].==("show"))["inputSchema"]["required"].as_a.map(&.as_s).should eq ["tenant_id"]
  end

  it "preserves required filter query arguments when an optional mount segment is omitted" do
    composition = CompositionOptionalFilteredHost.handler
    HotTopic.new(composition).get("/composition/optional-filtered/auth?tenant_id=42").headers["X-Tenant"].should eq "42"
    docs = AC::OpenAPI.generate_open_api_docs({} of String => AC::OpenAPI::KlassDoc, "test", "1", composition: composition)
    operation = docs[:paths]["/composition/optional-filtered/auth"].get.should_not be_nil
    params = operation.parameters.should_not be_nil
    params.first.in.should eq "query"
    params.first.required.should be_true
    schema = params.first.schema.should_not be_nil
    schema["type"].as_s.should eq "integer"
    tool = AC::MCPServer.generate_description(docs: false, composition: composition).toolboxes.first.tools.first
    tool.input_schema["required"].as_a.map(&.as_s).should eq ["tenant_id"]
  end
end
