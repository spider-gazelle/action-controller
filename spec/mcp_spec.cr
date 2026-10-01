require "./spec_helper"
require "../src/action-controller/mcp"

MCP_PORT = 6_123
MCP_URI  = URI.parse("http://127.0.0.1:#{MCP_PORT}/mcp")

# a minimal Streamable HTTP client
class MCPTestClient
  getter session_id : String? = nil

  def headers(accept = "application/json, text/event-stream", origin : String? = nil) : HTTP::Headers
    headers = HTTP::Headers{
      "Content-Type"  => "application/json",
      "Accept"        => accept,
      "Authorization" => "Bearer token",
    }
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

describe ActionController::MCPServer do
  server = ActionController::Server.new(MCP_PORT, "127.0.0.1")
  transport = ActionController::MCPServer.mount(server, "/mcp")

  before_all do
    # `crystal docs` only documents src/, so provide the fixture comments
    widget_docs = ActionController::OpenAPI::KlassDoc.new("McpWidgets", "Manages widgets, used by the MCP specs\n\nwidgets are not persisted")
    widget_docs.methods["show"] = "returns the widget requested"
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
      widgets.tools.map(&.name).should eq ["mcp_widgets_show", "mcp_widgets_create", "mcp_widgets_destroy"]

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
      client.tool_names.should eq ["list_toolboxes", "open_toolbox", "close_toolbox"]
    end

    it "lists the toolboxes" do
      client = MCPTestClient.new
      client.initialize_session
      result = client.call("list_toolboxes")
      result["isError"].should be_false
      toolboxes = result["structuredContent"]["toolboxes"].as_a
      widgets = toolboxes.find!(&.["name"].==("mcp_widgets"))
      widgets["tools"].should eq 3
      widgets["open"].should be_false
      widgets["description"].as_s.should start_with "Manages widgets"
    end

    it "opens and closes toolboxes, notifying inline via SSE" do
      client = MCPTestClient.new
      client.initialize_session

      messages = client.request("tools/call", {name: "open_toolbox", arguments: {name: "mcp_widgets"}}, accept: "application/json, text/event-stream")
      messages.size.should eq 2
      messages[0]["method"].should eq "notifications/tools/list_changed"
      messages[1]["result"]["content"][0]["text"].as_s.should contain "mcp_widgets_show"
      client.tool_names.should eq ["list_toolboxes", "open_toolbox", "close_toolbox", "mcp_widgets_show", "mcp_widgets_create", "mcp_widgets_destroy"]

      # sessions are independent
      other = MCPTestClient.new
      other.initialize_session
      other.tool_names.size.should eq 3

      # already open, nothing changed
      messages = client.request("tools/call", {name: "open_toolbox", arguments: {name: "mcp_widgets"}}, accept: "application/json, text/event-stream")
      messages.size.should eq 1

      messages = client.request("tools/call", {name: "close_toolbox", arguments: {name: "mcp_widgets"}}, accept: "application/json, text/event-stream")
      messages[0]["method"].should eq "notifications/tools/list_changed"
      client.tool_names.size.should eq 3
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
      result["structuredContent"].should eq JSON.parse(%({"name":"widget-12-acme","size":10}))
      JSON.parse(result["content"][0]["text"].as_s)["name"].should eq "widget-12-acme"
    end

    it "invokes routes with a request body" do
      client = MCPTestClient.new
      client.initialize_session
      client.call("open_toolbox", {name: "mcp_widgets"})

      result = client.call("mcp_widgets_create", {body: {name: "new", size: 3}})
      result["isError"].should be_false
      result["structuredContent"]["name"].should eq "new"
    end

    it "reports empty responses using the status" do
      client = MCPTestClient.new
      client.initialize_session
      client.call("open_toolbox", {name: "mcp_widgets"})

      result = client.call("mcp_widgets_destroy", {id: 4})
      result["isError"].should be_false
      result["content"][0]["text"].should eq "202 Accepted"
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
      result["content"][0]["text"].as_s.should start_with "401"
    end
  end

  it "tracks sessions in the transport" do
    (transport.sessions.size > 0).should be_true
  end
end
