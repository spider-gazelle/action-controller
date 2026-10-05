require "./spec_helper"
require "../src/action-controller/mcp"

MCP_PORT = 6_123
MCP_URI  = URI.parse("http://127.0.0.1:#{MCP_PORT}/mcp")

# a minimal Streamable HTTP client
class MCPTestClient
  getter session_id : String? = nil

  # credentials sent with each request, `nil` for none
  property authorization : String? = "Bearer token"

  def headers(accept = "application/json, text/event-stream", origin : String? = nil) : HTTP::Headers
    headers = HTTP::Headers{
      "Content-Type" => "application/json",
      "Accept"       => accept,
    }
    headers["Authorization"] = @authorization.as(String) if @authorization
    headers["Mcp-Session-Id"] = @session_id.as(String) if @session_id
    headers["Origin"] = origin if origin
    headers
  end

  def post(body, accept = "application/json, text/event-stream", origin = nil) : HTTP::Client::Response
    HTTP::Client.post(MCP_URI, headers: headers(accept, origin), body: body.to_json)
  end

  def initialize_session : JSON::Any
    response = post({jsonrpc: "2.0", id: 1, method: "initialize", params: {
      protocolVersion: "2025-11-25",
      capabilities:    {} of String => String,
      clientInfo:      {name: "spec", version: "1.0"},
    }})
    @session_id = response.headers["Mcp-Session-Id"]
    post({jsonrpc: "2.0", method: "notifications/initialized"}).status_code.should eq 202
    JSON.parse(response.body)
  end

  # returns the JSON-RPC messages in the response
  def request(method : String, params = {} of String => String, accept = "application/json") : Array(JSON::Any)
    response = post({jsonrpc: "2.0", id: 2, method: method, params: params}, accept)
    response.status_code.should eq 200
    if response.content_type == "text/event-stream"
      response.body.split("\n\n").compact_map do |event|
        data = event.lines.find(&.starts_with?("data: "))
        JSON.parse(data.lchop("data: ")) if data
      end
    else
      [JSON.parse(response.body)]
    end
  end

  def call(tool : String, arguments = {} of String => String, accept = "application/json") : JSON::Any
    request("tools/call", {name: tool, arguments: arguments}, accept).last["result"]
  end

  def tool_names : Array(String)
    request("tools/list").last["result"]["tools"].as_a.map(&.["name"].as_s)
  end
end

# meta tools followed by the root tools
DEFAULT_TOOLS = ["list_toolboxes", "open_toolbox", "close_toolbox", "mcp_widgets_colours", "mcp_root_time", "mcp_root_pixel"]

MCP_INIT = {jsonrpc: "2.0", id: 1, method: "initialize", params: {protocolVersion: "2025-11-25"}}

# configures MCP authentication for the duration of the block
def with_mcp_auth(transport, authenticator = nil, probe = nil, metadata = nil, &)
  ActionController::MCPServer.authenticator = authenticator
  ActionController::MCPServer.auth_probe = probe
  ActionController::MCPServer.resource_metadata = metadata
  transport.auth_cache.clear
  yield
ensure
  ActionController::MCPServer.authenticator = nil
  ActionController::MCPServer.auth_probe = nil
  ActionController::MCPServer.resource_metadata = nil
  transport.auth_cache.clear
end

describe ActionController::MCPServer do
  server = ActionController::Server.new(MCP_PORT, "127.0.0.1")
  transport = ActionController::MCPServer.mount(server, "/mcp")

  before_all do
    # `crystal docs` only documents src/, so provide the fixture comments
    widget_docs = ActionController::OpenAPI::KlassDoc.new("McpWidgets", "Manages widgets, used by the MCP specs\n\nwidgets are not persisted")
    widget_docs.methods["show"] = "returns the widget requested"
    widget_docs.methods["summarise"] = "summarise a widget for the user"
    ActionController::MCPServer.description = ActionController::MCPServer.generate_description({"McpWidgets" => widget_docs})
    bound = Channel(Nil).new
    spawn { server.run { bound.send nil } }
    bound.receive
  end

  after_all do
    server.close
    ActionController::MCPServer.description = nil
  end

  describe "description" do
    it "builds toolboxes from the documented routes" do
      description = ActionController::MCPServer.description
      widgets = description.toolbox?("mcp_widgets").should_not be_nil
      widgets.controller.should eq "McpWidgets"
      widgets.description.should eq "Manages widgets, used by the MCP specs\n\nwidgets are not persisted"
      widgets.tools.map(&.name).should eq ["mcp_widgets_show", "mcp_widgets_create", "mcp_widgets_destroy", "mcp_widgets_colours"]

      show = widgets.tools.first
      show.description.should eq "returns the widget requested"
      widgets.tools[1].description.should eq "POST /mcp_widgets"
      show.verb.should eq "get"
      show.path.should eq "/mcp_widgets/:id"
      show.params.map { |param| {param.name, param.in} }.should eq [{"id", "path"}, {"detailed", "query"}, {"X-Tenant", "header"}]

      schema = show.input_schema
      schema["required"].as_a.should eq ["id"]
      schema["properties"]["detailed"]["description"].should eq "include the widget size"
      schema["properties"]["detailed"]["examples"].as_a.should eq ["true"]
      schema["properties"]["X-Tenant"]["type"].as_a.should eq ["string", "null"]
      schema["properties"]["X-Tenant"]["nullable"]?.should be_nil
    end

    it "includes the request body schema as $defs" do
      create = ActionController::MCPServer.description.tool?("mcp_widgets_create").should_not be_nil
      tool = create[1]
      tool.body.should eq "body"
      schema = tool.input_schema
      schema["required"].as_a.should eq ["body"]
      ref = schema["properties"]["body"]["$ref"].as_s
      ref.should start_with "#/$defs/"
      schema["$defs"][ref.lchop("#/$defs/")]["properties"]["name"]["type"].should eq "string"
    end

    it "excludes hidden and websocket routes" do
      description = ActionController::MCPServer.description
      description.tool?("mcp_widgets_secret").should be_nil
      description.tool?("mcp_widgets_websocket").should be_nil
      hidden = description.toolbox?("mcp_hidden").should_not be_nil
      hidden.tools.map(&.name).should eq ["mcp_hidden_visible"]
    end

    it "generates a single tool for a method with several routes" do
      # Filtering#other_route_test has three GET routes, the first is used
      filtering = ActionController::MCPServer.description.toolbox?("filtering").should_not be_nil
      tools = filtering.tools.select(&.name.starts_with?("filtering_other_route_test"))
      tools.map(&.name).should eq ["filtering_other_route_test"]
      tools.first.path.should eq "/filtering/other_route/:id/test"
    end

    it "omits the namespace shared by every controller from names" do
      namespace = ActionController::MCPServer.common_namespace(["PlaceOS::Api::Zones", "PlaceOS::Api::Groups::Users", "PlaceOS::Api::OAuthApplications"])
      namespace.should eq ["PlaceOS", "Api"]
      ActionController::MCPServer.toolbox_name("PlaceOS::Api::Zones", namespace).should eq "zones"
      ActionController::MCPServer.toolbox_name("PlaceOS::Api::Groups::Users", namespace).should eq "groups_users"
      ActionController::MCPServer.toolbox_name("PlaceOS::Api::OAuthApplications", namespace).should eq "o_auth_applications"

      # only whole modules are shared, a controller's own name is never removed
      ActionController::MCPServer.common_namespace(["Admin::Users", "Users"]).should be_empty
      ActionController::MCPServer.common_namespace(["Api::V1::Users", "Api::V2::Users"]).should eq ["Api"]
      ActionController::MCPServer.common_namespace(["Api::Users"]).should eq ["Api"]
      ActionController::MCPServer.toolbox_name("Api::Users", ["Api"]).should eq "users"
      ActionController::MCPServer.common_namespace([] of String).should be_empty

      # the spec controllers aren't namespaced
      ActionController::MCPServer.description.toolbox?("mcp_widgets").should_not be_nil
    end

    it "round trips via YAML" do
      yaml = ActionController::MCPServer.description.to_yaml
      parsed = ActionController::MCPServer::Description.from_yaml(yaml)
      parsed.to_yaml.should eq yaml
      original = ActionController::MCPServer.description.tool?("mcp_widgets_show").should_not be_nil
      loaded = parsed.tool?("mcp_widgets_show").should_not be_nil
      loaded[1].input_schema.should eq original[1].input_schema
    end
  end

  describe "transport" do
    it "initializes a session" do
      client = MCPTestClient.new
      result = client.initialize_session["result"]
      client.session_id.should_not be_nil
      result["protocolVersion"].should eq "2025-11-25"
      result["capabilities"]["tools"]["listChanged"].should be_true
      result["instructions"].as_s.should contain "list_toolboxes"
    end

    it "negotiates the protocol version" do
      response = MCPTestClient.new.post({jsonrpc: "2.0", id: 1, method: "initialize", params: {protocolVersion: "1999-01-01"}})
      JSON.parse(response.body)["result"]["protocolVersion"].should eq ActionController::MCPServer::PROTOCOL_VERSIONS.first
    end

    it "requires a valid session" do
      client = MCPTestClient.new
      client.post({jsonrpc: "2.0", id: 2, method: "tools/list"}).status_code.should eq 400

      response = HTTP::Client.post(MCP_URI, headers: HTTP::Headers{"Mcp-Session-Id" => "unknown"}, body: {jsonrpc: "2.0", id: 2, method: "tools/list"}.to_json)
      response.status_code.should eq 404
    end

    it "rejects invalid messages" do
      response = HTTP::Client.post(MCP_URI, body: "{not json")
      response.status_code.should eq 400
      JSON.parse(response.body)["error"]["code"].should eq -32700

      client = MCPTestClient.new
      client.initialize_session
      client.request("does/not/exist").first["error"]["code"].should eq -32601
    end

    it "validates the origin and protocol version headers" do
      client = MCPTestClient.new
      client.initialize_session
      client.post({jsonrpc: "2.0", id: 2, method: "ping"}, origin: "http://evil.example.com").status_code.should eq 403
      client.post({jsonrpc: "2.0", id: 2, method: "ping"}, origin: "http://127.0.0.1:#{MCP_PORT}").status_code.should eq 200

      headers = client.headers
      headers["MCP-Protocol-Version"] = "1999-01-01"
      HTTP::Client.post(MCP_URI, headers: headers, body: {jsonrpc: "2.0", id: 2, method: "ping"}.to_json).status_code.should eq 400
    end

    it "terminates a session" do
      client = MCPTestClient.new
      client.initialize_session
      HTTP::Client.delete(MCP_URI, headers: client.headers).status_code.should eq 204
      client.post({jsonrpc: "2.0", id: 2, method: "ping"}).status_code.should eq 404
    end
  end

  describe "toolboxes" do
    it "only lists the meta tools by default" do
      client = MCPTestClient.new
      client.initialize_session
      client.tool_names.should eq DEFAULT_TOOLS
    end

    it "lists the toolboxes" do
      client = MCPTestClient.new
      client.initialize_session
      result = client.call("list_toolboxes")
      result["isError"].should be_false
      toolboxes = result["structuredContent"]["toolboxes"].as_a
      widgets = toolboxes.find!(&.["name"].==("mcp_widgets"))
      widgets["tools"].should eq 3
      widgets["prompts"].should eq 1
      widgets["open"].should be_false
      widgets["description"].as_s.should start_with "Manages widgets"
    end

    it "opens and closes toolboxes, notifying inline via SSE" do
      client = MCPTestClient.new
      client.initialize_session

      messages = client.request("tools/call", {name: "open_toolbox", arguments: {name: "mcp_widgets"}}, accept: "application/json, text/event-stream")
      messages.size.should eq 3
      messages[0]["method"].should eq "notifications/tools/list_changed"
      messages[1]["method"].should eq "notifications/prompts/list_changed"
      messages[2]["result"]["content"][0]["text"].as_s.should contain "mcp_widgets_show"
      client.tool_names.should eq DEFAULT_TOOLS + ["mcp_widgets_show", "mcp_widgets_create", "mcp_widgets_destroy"]

      # sessions are independent
      other = MCPTestClient.new
      other.initialize_session
      other.tool_names.should eq DEFAULT_TOOLS

      # already open, nothing changed
      messages = client.request("tools/call", {name: "open_toolbox", arguments: {name: "mcp_widgets"}}, accept: "application/json, text/event-stream")
      messages.size.should eq 1

      messages = client.request("tools/call", {name: "close_toolbox", arguments: {name: "mcp_widgets"}}, accept: "application/json, text/event-stream")
      messages[0]["method"].should eq "notifications/tools/list_changed"
      messages[1]["method"].should eq "notifications/prompts/list_changed"
      client.tool_names.should eq DEFAULT_TOOLS
    end

    it "reports unknown toolboxes as tool errors" do
      client = MCPTestClient.new
      client.initialize_session
      result = client.call("open_toolbox", {name: "nope"})
      result["isError"].should be_true
      result["content"][0]["text"].as_s.should contain "Unknown toolbox"
    end

    it "delivers notifications on the GET event stream" do
      client = MCPTestClient.new
      client.initialize_session

      received = Channel(String).new(1)
      spawn do
        HTTP::Client.get(MCP_URI, headers: client.headers(accept: "text/event-stream")) do |response|
          response.status_code.should eq 200
          while line = response.body_io.gets
            if line.starts_with?("data: ")
              received.send line.lchop("data: ")
              break
            end
          end
        end
      end
      Fiber.yield

      # JSON only client, so the notification is sent via the stream
      client.call("open_toolbox", {name: "mcp_widgets"}, accept: "application/json")["isError"].should be_false

      select
      when message = received.receive
        JSON.parse(message)["method"].should eq "notifications/tools/list_changed"
      when timeout(5.seconds)
        fail "notification not received"
      end
    end

    sse = "application/json, text/event-stream"
    notifications = ->(messages : Array(JSON::Any)) { messages.compact_map(&.["method"]?.try(&.as_s)) }

    # streams a session's GET event stream: "connected" once it's open, the data of
    # each event, then `nil` when the stream ends
    open_stream = ->(client : MCPTestClient) do
      events = Channel(String?).new(32)
      spawn do
        HTTP::Client.get(MCP_URI, headers: client.headers(accept: "text/event-stream")) do |response|
          response.status_code.should eq 200
          events.send "connected"
          while line = response.body_io.gets
            events.send line.lchop("data: ") if line.starts_with?("data: ")
          end
        end
        events.send nil
      end
      events
    end

    next_event = ->(events : Channel(String?)) do
      select
      when event = events.receive
        event
      when timeout(5.seconds)
        fail "no event received"
      end
    end

    it "only notifies about the lists that changed" do
      client = MCPTestClient.new
      client.initialize_session

      # tools but no prompts
      notifications.call(client.request("tools/call", {name: "open_toolbox", arguments: {name: "mcp_hidden"}}, accept: sse))
        .should eq ["notifications/tools/list_changed"]

      # prompts but no tools
      notifications.call(client.request("tools/call", {name: "open_toolbox", arguments: {name: "mcp_prompts_only"}}, accept: sse))
        .should eq ["notifications/prompts/list_changed"]
      client.request("prompts/list").last["result"]["prompts"].as_a.map(&.["name"].as_s).should contain "mcp_prompts_only_greeting"

      notifications.call(client.request("tools/call", {name: "close_toolbox", arguments: {name: "mcp_prompts_only"}}, accept: sse))
        .should eq ["notifications/prompts/list_changed"]
      notifications.call(client.request("tools/call", {name: "close_toolbox", arguments: {name: "mcp_hidden"}}, accept: sse))
        .should eq ["notifications/tools/list_changed"]

      # closing a toolbox that isn't open changes nothing
      notifications.call(client.request("tools/call", {name: "close_toolbox", arguments: {name: "mcp_hidden"}}, accept: sse)).should be_empty
    end

    it "delivers every notification on the GET event stream" do
      client = MCPTestClient.new
      client.initialize_session
      events = open_stream.call(client)
      next_event.call(events).should eq "connected"

      client.call("open_toolbox", {name: "mcp_widgets"})["isError"].should be_false
      client.call("close_toolbox", {name: "mcp_widgets"})["isError"].should be_false

      methods = Array.new(4) { JSON.parse(next_event.call(events).to_s)["method"].as_s }
      methods.should eq [
        "notifications/tools/list_changed", "notifications/prompts/list_changed",
        "notifications/tools/list_changed", "notifications/prompts/list_changed",
      ]
    end

    it "ends the event stream when the session ends" do
      client = MCPTestClient.new
      client.initialize_session
      events = open_stream.call(client)
      next_event.call(events).should eq "connected"

      HTTP::Client.delete(MCP_URI, headers: client.headers).status_code.should eq 204
      next_event.call(events).should be_nil
    end

    it "rejects tools from closed toolboxes" do
      client = MCPTestClient.new
      client.initialize_session
      error = client.request("tools/call", {name: "mcp_widgets_show", arguments: {id: 1}}).first["error"]
      error["code"].should eq -32602
      error["message"].as_s.should contain "open the mcp_widgets toolbox"
    end
  end

  describe "tool calls" do
    it "invokes routes with path, query and header arguments" do
      client = MCPTestClient.new
      client.initialize_session
      client.call("open_toolbox", {name: "mcp_widgets"})

      result = client.call("mcp_widgets_show", {"id" => JSON::Any.new(12_i64), "detailed" => JSON::Any.new(true), "X-Tenant" => JSON::Any.new("acme")})
      result["isError"].should be_false
      result["structuredContent"].should eq JSON.parse(%({"status":200,"body":{"name":"widget-12-acme","size":10}}))
      # the text is the same envelope, for clients that only pass text to the model
      JSON.parse(result["content"][0]["text"].as_s).should eq result["structuredContent"]
    end

    it "invokes routes with a request body" do
      client = MCPTestClient.new
      client.initialize_session
      client.call("open_toolbox", {name: "mcp_widgets"})

      result = client.call("mcp_widgets_create", {body: {name: "new", size: 3}})
      result["isError"].should be_false
      result["structuredContent"]["status"].should eq 201
      result["structuredContent"]["body"]["name"].should eq "new"
    end

    it "reports empty responses using the status" do
      client = MCPTestClient.new
      client.initialize_session
      client.call("open_toolbox", {name: "mcp_widgets"})

      result = client.call("mcp_widgets_destroy", {id: 4})
      result["isError"].should be_false
      result["content"][0]["text"].should eq %({"status":202})
      result["structuredContent"].should eq JSON.parse(%({"status":202}))
    end

    it "flags HTTP errors" do
      client = MCPTestClient.new
      client.initialize_session
      client.call("open_toolbox", {name: "mcp_widgets"})

      result = client.call("mcp_widgets_show", {id: "not-a-number"})
      result["isError"].should be_true

      result = client.call("mcp_widgets_show", {} of String => String)
      result["isError"].should be_true
      result["content"][0]["text"].as_s.should contain "missing required argument: id"
    end

    it "forwards authentication headers" do
      client = MCPTestClient.new
      client.initialize_session
      client.call("open_toolbox", {name: "mcp_widgets"})

      headers = client.headers(accept: "application/json")
      headers["Authorization"] = "Bearer wrong"
      response = HTTP::Client.post(MCP_URI, headers: headers, body: {jsonrpc: "2.0", id: 3, method: "tools/call", params: {name: "mcp_widgets_show", arguments: {id: 1}}}.to_json)
      result = JSON.parse(response.body)["result"]
      result["isError"].should be_true
      result["structuredContent"]["status"].should eq 401
    end
  end

  describe "response headers" do
    it "returns useful headers and leaves out excluded ones" do
      client = MCPTestClient.new
      client.initialize_session

      result = client.call("mcp_widgets_colours")
      result["structuredContent"].should eq JSON.parse({
        status:  200,
        headers: {"X-Total-Count" => "2", "Link" => %(</mcp_widgets/colours?page=2>; rel="next")},
        body:    ["red", "green"],
      }.to_json)
    end

    it "returns media as its own content block" do
      client = MCPTestClient.new
      client.initialize_session

      result = client.call("mcp_root_pixel")
      result["content"][0].should eq JSON.parse(%({"type":"image","data":"iVBORw==","mimeType":"image/png"}))
      result["content"][1]["text"].should eq %({"status":200,"headers":{"ETag":"\\"pixel\\""}})
      result["structuredContent"].should eq JSON.parse(%({"status":200,"headers":{"ETag":"\\"pixel\\""}}))
    end

    it "can be configured" do
      original = ActionController::MCPServer.excluded_response_headers
      ActionController::MCPServer.excluded_response_headers = original + ["link", "X-Total-*"]
      begin
        client = MCPTestClient.new
        client.initialize_session
        client.call("mcp_widgets_colours")["structuredContent"].should eq JSON.parse(%({"status": 200, "body": ["red", "green"]}))
      ensure
        ActionController::MCPServer.excluded_response_headers = original
      end
    end

    it "matches names case-insensitively and by prefix" do
      headers = HTTP::Headers{
        "set-cookie" => "a=b", "DATE" => "today", "Access-Control-Allow-Origin" => "*",
        "Proxy-Authenticate" => "Basic", "ETag" => %("abc"), "Retry-After" => "5",
      }
      headers.add("Link", "<a>; rel=\"next\"")
      headers.add("Link", "<b>; rel=\"last\"")
      ActionController::MCPServer.visible_headers(headers).should eq({
        "ETag" => %("abc"), "Retry-After" => "5", "Link" => %(<a>; rel="next", <b>; rel="last"),
      })
    end
  end

  describe "prompts" do
    it "describes prompts" do
      description = ActionController::MCPServer.description
      widgets = description.toolbox?("mcp_widgets").should_not be_nil
      widgets.prompts.map(&.name).should eq ["mcp_widgets_summarise", "mcp_widgets_review"]

      summarise = widgets.prompts.first
      summarise.description.should eq "summarise a widget for the user"
      summarise.root?.should be_false
      summarise.arguments.map { |arg| {arg.name, arg.in, arg.description, arg.required?} }.should eq [
        {"id", "query", nil, true},
        {"tone", "query", "the tone of the summary", false},
      ]
      widgets.prompts.last.root?.should be_true

      hidden = description.toolbox?("mcp_hidden").should_not be_nil
      hidden.prompts.should be_empty
      root = description.toolbox?("mcp_root").should_not be_nil
      root.prompts.map(&.name).should eq ["mcp_root_greet"]
    end

    it "are not HTTP routes" do
      headers = HTTP::Headers{"Authorization" => "Bearer token"}
      HTTP::Client.get("http://127.0.0.1:#{MCP_PORT}/mcp_widgets/__mcp_prompt__/summarise?id=1", headers: headers).status_code.should eq 404
      ActionController::Server.routes.map(&.[1]).should_not contain :summarise
      ActionController::OpenAPI.generate_open_api_docs("title", "version")[:paths].keys.select(&.includes?("__mcp_prompt__")).should be_empty
    end

    it "advertises the prompts capability" do
      client = MCPTestClient.new
      client.initialize_session["result"]["capabilities"]["prompts"]["listChanged"].should be_true
    end

    it "lists root prompts and the prompts of open toolboxes" do
      client = MCPTestClient.new
      client.initialize_session
      prompt_names = -> { client.request("prompts/list").last["result"]["prompts"].as_a.map(&.["name"].as_s) }
      prompt_names.call.should eq ["mcp_widgets_review", "mcp_root_greet"]

      client.call("open_toolbox", {name: "mcp_widgets"})
      prompt_names.call.should eq ["mcp_widgets_review", "mcp_root_greet", "mcp_widgets_summarise"]

      prompt = client.request("prompts/list").last["result"]["prompts"].as_a.last
      prompt["description"].should eq "summarise a widget for the user"
      prompt["arguments"].as_a.should eq [
        JSON.parse(%({"name":"id","required":true})),
        JSON.parse(%({"name":"tone","description":"the tone of the summary","required":false})),
      ]

      client.call("close_toolbox", {name: "mcp_widgets"})
      prompt_names.call.should eq ["mcp_widgets_review", "mcp_root_greet"]
    end

    it "renders single message prompts" do
      client = MCPTestClient.new
      client.initialize_session
      client.call("open_toolbox", {name: "mcp_widgets"})

      result = client.request("prompts/get", {name: "mcp_widgets_summarise", arguments: {id: "5", tone: "formal"}}).last["result"]
      result["description"].should eq "summarise a widget for the user"
      result["messages"].should eq JSON.parse(%([{"role":"user","content":{"type":"text","text":"Summarise widget 5 in a formal tone"}}]))

      result = client.request("prompts/get", {name: "mcp_widgets_summarise", arguments: {id: "5"}}).last["result"]
      result["messages"][0]["content"]["text"].should eq "Summarise widget 5 in a casual tone"
    end

    it "renders multi-message root prompts without opening the toolbox" do
      client = MCPTestClient.new
      client.initialize_session
      messages = client.request("prompts/get", {name: "mcp_widgets_review", arguments: {id: "2"}}).last["result"]["messages"].as_a
      messages.map { |message| {message["role"].as_s, message["content"]["text"].as_s} }.should eq [
        {"user", "Review widget 2"},
        {"assistant", "Which aspects should I focus on?"},
      ]
    end

    it "reports prompt errors" do
      client = MCPTestClient.new
      client.initialize_session

      # toolbox is closed
      error = client.request("prompts/get", {name: "mcp_widgets_summarise", arguments: {id: "1"}}).last["error"]
      error["code"].should eq -32602
      error["message"].as_s.should contain "open the mcp_widgets toolbox"

      # missing required argument
      error = client.request("prompts/get", {name: "mcp_widgets_review"}).last["error"]
      error["code"].should eq -32602
      error["message"].should eq "missing required argument: id"

      # argument that can't be parsed
      client.request("prompts/get", {name: "mcp_widgets_review", arguments: {id: "abc"}}).last["error"]["code"].should eq -32603

      # unknown prompt
      client.request("prompts/get", {name: "nope"}).last["error"]["code"].should eq -32602
    end

    it "runs the controller filters" do
      client = MCPTestClient.new
      client.authorization = "Bearer wrong"
      client.initialize_session
      error = client.request("prompts/get", {name: "mcp_widgets_review", arguments: {id: "2"}}).last["error"]
      error["code"].should eq -32602
      error["message"].as_s.should start_with "401"
    end

    it "escalates prompts rejected by the application when authentication is enabled" do
      metadata = ->(_request : HTTP::Request) do
        ActionController::MCPServer::ResourceMetadata.new(["https://auth.example.com"])
      end

      with_mcp_auth(transport, metadata: metadata) do
        client = MCPTestClient.new
        client.authorization = "Bearer expired"
        client.initialize_session
        response = client.post({jsonrpc: "2.0", id: 3, method: "prompts/get", params: {name: "mcp_widgets_review", arguments: {id: "2"}}})
        response.status_code.should eq 401
      end
    end
  end

  describe "root items" do
    it "calls root tools without opening the toolbox" do
      client = MCPTestClient.new
      client.initialize_session
      result = client.call("mcp_widgets_colours")
      result["isError"].should be_false
      result["structuredContent"]["body"].should eq JSON.parse(%(["red","green"]))
      client.call("mcp_root_time")["structuredContent"]["body"].should eq "noon"
    end

    it "omits toolboxes that only contain root items" do
      client = MCPTestClient.new
      client.initialize_session
      names = client.call("list_toolboxes")["structuredContent"]["toolboxes"].as_a.map(&.["name"].as_s)
      names.should contain "mcp_widgets"
      names.should_not contain "mcp_root"
      client.call("open_toolbox", {name: "mcp_root"})["isError"].should be_true
    end
  end

  describe "authentication" do
    it "is optional" do
      ActionController::MCPServer.auth_enabled?.should be_false
      client = MCPTestClient.new
      client.authorization = nil
      client.initialize_session["result"]["protocolVersion"].should eq "2025-11-25"
      client.tool_names.should eq DEFAULT_TOOLS
    end

    it "authenticates every request with the authenticator" do
      calls = 0
      authenticator = ->(request : HTTP::Request) do
        calls += 1
        request.headers["Authorization"]? == "Bearer token"
      end

      with_mcp_auth(transport, authenticator: authenticator) do
        anonymous = MCPTestClient.new
        anonymous.authorization = nil
        response = anonymous.post(MCP_INIT)
        response.status_code.should eq 401
        response.headers["WWW-Authenticate"].should eq "Bearer"
        response.headers["Mcp-Session-Id"]?.should be_nil

        invalid = MCPTestClient.new
        invalid.authorization = "Bearer wrong"
        response = invalid.post(MCP_INIT)
        response.status_code.should eq 401
        response.headers["WWW-Authenticate"].should eq %(Bearer error="invalid_token")

        client = MCPTestClient.new
        client.initialize_session
        client.tool_names.should eq DEFAULT_TOOLS

        # successful checks are cached
        calls.should eq 3

        # the event stream and session termination require authentication
        headers = client.headers(accept: "text/event-stream")
        headers.delete("Authorization")
        HTTP::Client.get(MCP_URI, headers: headers).status_code.should eq 401
        HTTP::Client.delete(MCP_URI, headers: headers).status_code.should eq 401
      end
    end

    it "authenticates using a probe route" do
      with_mcp_auth(transport, probe: "/mcp_widgets/1") do
        invalid = MCPTestClient.new
        invalid.authorization = "Bearer wrong"
        response = invalid.post(MCP_INIT)
        response.status_code.should eq 401
        response.headers["WWW-Authenticate"].should eq %(Bearer error="invalid_token")

        client = MCPTestClient.new
        client.initialize_session["result"]["protocolVersion"].should eq "2025-11-25"
      end
    end

    it "advertises the authorization server" do
      metadata = ->(request : HTTP::Request) do
        ActionController::MCPServer::ResourceMetadata.new(["https://#{request.hostname}/auth"], ["public"])
      end

      with_mcp_auth(transport, metadata: metadata) do
        anonymous = MCPTestClient.new
        anonymous.authorization = nil
        response = anonymous.post(MCP_INIT)
        response.status_code.should eq 401
        metadata_url = "http://127.0.0.1:#{MCP_PORT}/.well-known/oauth-protected-resource/mcp"
        response.headers["WWW-Authenticate"].should eq %(Bearer resource_metadata="#{metadata_url}", scope="public")

        document = JSON.parse(HTTP::Client.get(metadata_url).body)
        document["resource"].should eq "http://127.0.0.1:#{MCP_PORT}/mcp"
        document["authorization_servers"].as_a.should eq ["https://127.0.0.1/auth"]
        document["scopes_supported"].as_a.should eq ["public"]
        document["bearer_methods_supported"].as_a.should eq ["header"]

        # resource URLs are per tenant
        tenant = HTTP::Headers{"Host" => "tenant.example.com", "X-Forwarded-Proto" => "https"}
        document = JSON.parse(HTTP::Client.get(metadata_url, headers: tenant).body)
        document["resource"].should eq "https://tenant.example.com/mcp"
        document["authorization_servers"].as_a.should eq ["https://tenant.example.com/auth"]
      end

      HTTP::Client.get("http://127.0.0.1:#{MCP_PORT}/.well-known/oauth-protected-resource/mcp").status_code.should eq 404
    end

    it "escalates tool calls rejected by the application" do
      metadata = ->(_request : HTTP::Request) do
        ActionController::MCPServer::ResourceMetadata.new(["https://auth.example.com"])
      end

      with_mcp_auth(transport, metadata: metadata) do
        # credentials are present so the session can be established
        client = MCPTestClient.new
        client.authorization = "Bearer expired"
        client.initialize_session
        client.call("open_toolbox", {name: "mcp_widgets"})["isError"].should be_false

        fingerprint = ActionController::MCPServer::AuthCache.fingerprint(
          HTTP::Request.new("POST", "/mcp", HTTP::Headers{"Host" => "127.0.0.1:#{MCP_PORT}", "Authorization" => "Bearer expired"})
        ).should_not be_nil
        transport.auth_cache.valid?(fingerprint).should be_true

        # the route responds with a 401, which is returned to the client
        response = client.post({jsonrpc: "2.0", id: 3, method: "tools/call", params: {name: "mcp_widgets_show", arguments: {id: 1}}})
        response.status_code.should eq 401
        response.headers["WWW-Authenticate"].should eq %(Bearer resource_metadata="http://127.0.0.1:#{MCP_PORT}/.well-known/oauth-protected-resource/mcp", error="invalid_token")
        transport.auth_cache.valid?(fingerprint).should be_false

        # once refreshed the tool call succeeds
        client.authorization = "Bearer token"
        client.call("mcp_widgets_show", {id: 1})["isError"].should be_false
      end
    end

    it "forwards API keys by default" do
      origin = HTTP::Request.new("POST", "/mcp", HTTP::Headers{"X-API-Key" => "id.secret", "X-Other" => "nope", "Host" => "example.com"})
      headers = ActionController::MCPServer::Invoker.new(server.route_handler).forwarded_headers(origin)
      headers["X-API-Key"].should eq "id.secret"
      headers["Host"].should eq "example.com"
      headers.has_key?("X-Other").should be_false
    end
  end

  it "tracks sessions in the transport" do
    MCPTestClient.new.initialize_session
    (transport.sessions.size > 0).should be_true
  end
end

describe ActionController::MCPServer::Session do
  it "drops notifications rather than blocking when nobody is listening" do
    session = ActionController::MCPServer::Session.new("2025-11-25")

    notified = Channel(Nil).new(1)
    spawn do
      40.times { |index| session.notify(%({"index":#{index}})) }
      notified.send nil
    end
    select
    when notified.receive
    when timeout(5.seconds)
      fail "notify blocked"
    end

    queued = 0
    loop do
      select
      when session.notifications.receive
        queued += 1
      else
        break
      end
    end
    queued.should eq 32

    # notifying an ended session is ignored
    session.terminate
    session.notify(%({"index":41}))
  end
end
