require "./spec_helper"
require "../src/action-controller/mcp"
require "file_utils"

MCP_PORT = 6_123
MCP_URI  = URI.parse("http://127.0.0.1:#{MCP_PORT}/mcp")

MODERN_VERSION = "2026-07-28"

# a minimal Streamable HTTP client.
#
# `modern: true` speaks 2026-07-28: there's no `initialize`, every request carries its
# protocol version and client capabilities in `_meta` and the matching headers
class MCPTestClient
  # the legacy session id, if the server ever assigns one
  getter session_id : String? = nil

  # the protocol version sent with each request, `nil` before initialization
  getter protocol_version : String? = nil

  # credentials sent with each request, `nil` for none
  property authorization : String? = "Bearer token"

  getter? modern : Bool

  def initialize(@uri : URI = MCP_URI, @modern : Bool = false)
    @protocol_version = MODERN_VERSION if @modern
  end

  def headers(accept = "application/json, text/event-stream", origin : String? = nil) : HTTP::Headers
    headers = HTTP::Headers{
      "Content-Type" => "application/json",
      "Accept"       => accept,
    }
    headers["Authorization"] = @authorization.as(String) if @authorization
    headers["Mcp-Session-Id"] = @session_id.as(String) if @session_id
    headers["MCP-Protocol-Version"] = @protocol_version.as(String) if @protocol_version
    headers["Origin"] = origin if origin
    headers
  end

  # modern requests also carry the `_meta` fields and the method and name headers
  def post(body, accept = "application/json, text/event-stream", origin = nil) : HTTP::Client::Response
    headers, payload = prepare(body, accept, origin)
    HTTP::Client.post(@uri, headers: headers, body: payload)
  end

  # the headers and body of a request
  def prepare(body, accept = "application/json, text/event-stream", origin = nil) : Tuple(HTTP::Headers, String)
    message = JSON.parse(body.to_json).as_h
    headers = headers(accept, origin)
    if modern? && (method = message["method"]?.try(&.as_s))
      params = message["params"]?.try(&.as_h) || {} of String => JSON::Any
      meta = params["_meta"]?.try(&.as_h) || {} of String => JSON::Any
      meta["io.modelcontextprotocol/protocolVersion"] ||= JSON::Any.new(MODERN_VERSION)
      meta["io.modelcontextprotocol/clientCapabilities"] ||= JSON.parse("{}")
      params["_meta"] = JSON::Any.new(meta)
      message["params"] = JSON::Any.new(params)
      headers["Mcp-Method"] = method
      if name = (params["name"]? || params["uri"]?).try(&.as_s?)
        headers["Mcp-Name"] = name if {"tools/call", "prompts/get", "resources/read"}.includes?(method)
      end
    end
    {headers, message.to_json}
  end

  # `ui: true` advertises MCP Apps support. Modern clients don't initialize, they
  # discover the server instead
  def initialize_session(ui : Bool = false) : JSON::Any
    capabilities = ui ? JSON.parse(%({"extensions": {"io.modelcontextprotocol/ui": {"mimeTypes": ["text/html;profile=mcp-app"]}}})) : JSON.parse("{}")
    if modern?
      return JSON.parse(post({jsonrpc: "2.0", id: 1, method: "server/discover", params: {
        _meta: {"io.modelcontextprotocol/clientCapabilities" => capabilities},
      }}).body)
    end

    response = post({jsonrpc: "2.0", id: 1, method: "initialize", params: {
      protocolVersion: "2025-11-25",
      capabilities:    capabilities,
      clientInfo:      {name: "spec", version: "1.0"},
    }})
    @session_id = response.headers["Mcp-Session-Id"]?
    result = JSON.parse(response.body)
    @protocol_version = result["result"]?.try(&.["protocolVersion"].as_s)
    post({jsonrpc: "2.0", method: "notifications/initialized"}).status_code.should eq 202
    result
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

  def tools : Array(JSON::Any)
    request("tools/list").last["result"]["tools"].as_a
  end

  # leaves out the tools of other spec files, as the description covers every controller
  def tool_names : Array(String)
    tools.map(&.["name"].as_s).reject(&.starts_with?("composition_"))
  end
end

# meta tools followed by the root tools, the same for every request
DEFAULT_TOOLS = ["list_toolboxes", "open_toolbox", "call_read_only", "call_tool", "mcp_widgets_colours", "mcp_ui_show", "mcp_ui_check_in", "mcp_ui_rooms", "mcp_root_time", "mcp_root_pixel"]

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
    account_docs = ActionController::OpenAPI::KlassDoc.new("McpAccount", "Manages an account, call show to look up its widgets")
    ActionController::MCPServer.description = ActionController::MCPServer.generate_description({"McpWidgets" => widget_docs, "McpAccount" => account_docs})
    ActionController::MCPServer.ui_base = File.join(__DIR__, "cards")
    ActionController::MCPServer.ui_meta = ActionController::MCPServer::UIMeta.new(prefers_border: true)
    ActionController::MCPServer.icon "logo.png", sizes: ["48x48"]
    bound = Channel(Nil).new
    spawn { server.run { bound.send nil } }
    bound.receive
  end

  after_all do
    server.close
    ActionController::MCPServer.ui_base = nil
    ActionController::MCPServer.ui_meta = nil
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
      schema["properties"]["detailed"]["examples"].as_a.should eq [true]
      schema["properties"]["X-Tenant"]["anyOf"].should eq JSON.parse(%([{"type":"null"},{"type":"string"}]))
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

      # behaviour is only stored when overridden
      tools = parsed.toolbox?("mcp_read_only").should_not be_nil
      tools = tools.tools
      tools.find!(&.name.==("mcp_read_only_search")).behaviour.should eq ["read_only"]
      tools.find!(&.name.==("mcp_read_only_touch")).behaviour.should eq ["additive"]
      widgets = parsed.toolbox?("mcp_widgets").should_not be_nil
      widgets.tools.all?(&.behaviour.nil?).should be_true

      # titles and icons too
      options = parsed.toolbox?("mcp_options").should_not be_nil
      options.icons.should eq [JSON.parse(%({"src": "icons/bell.svg", "sizes": ["any"]}))]
      email = options.tools.find!(&.name.==("mcp_options_email"))
      email.title.should eq "Send an email"
      email.icons.try(&.size).should eq 2
      options.prompts.first.title.should eq "Draft an email"
      original = ActionController::MCPServer.description.tool?("mcp_widgets_show").should_not be_nil
      loaded = parsed.tool?("mcp_widgets_show").should_not be_nil
      loaded[1].input_schema.should eq original[1].input_schema
    end
  end

  describe "transport" do
    it "initializes without a session" do
      client = MCPTestClient.new
      result = client.initialize_session["result"]
      client.session_id.should be_nil
      result["protocolVersion"].should eq "2025-11-25"
      result["capabilities"]["tools"]["listChanged"].should be_false
      result["instructions"].as_s.should contain "list_toolboxes"
      result["instructions"].as_s.should contain "call_tool"
    end

    it "negotiates the protocol version" do
      response = MCPTestClient.new.post({jsonrpc: "2.0", id: 1, method: "initialize", params: {protocolVersion: "1999-01-01"}})
      JSON.parse(response.body)["result"]["protocolVersion"].should eq "2025-11-25"

      # modern clients don't initialize
      response = MCPTestClient.new.post({jsonrpc: "2.0", id: 1, method: "initialize", params: {protocolVersion: MODERN_VERSION}})
      JSON.parse(response.body)["result"]["protocolVersion"].should eq "2025-11-25"
    end

    it "doesn't require a session" do
      # clients that never initialized are assumed to be 2025-03-26
      response = HTTP::Client.post(MCP_URI, headers: HTTP::Headers{"Content-Type" => "application/json"}, body: {jsonrpc: "2.0", id: 2, method: "tools/list"}.to_json)
      response.status_code.should eq 200
      JSON.parse(response.body)["result"]["tools"].as_a.map(&.["name"].as_s).reject(&.starts_with?("composition_")).should eq DEFAULT_TOOLS

      # unknown session ids are ignored
      headers = HTTP::Headers{"Content-Type" => "application/json", "Mcp-Session-Id" => "unknown", "MCP-Protocol-Version" => "2025-11-25"}
      response = HTTP::Client.post(MCP_URI, headers: headers, body: {jsonrpc: "2.0", id: 2, method: "ping"}.to_json)
      response.status_code.should eq 200
      response.headers["Mcp-Session-Id"]?.should be_nil
    end

    it "serves a conversation from any server" do
      other = ActionController::Server.new(MCP_PORT + 1, "127.0.0.1")
      ActionController::MCPServer.mount(other, "/mcp")
      bound = Channel(Nil).new
      spawn { other.run { bound.send nil } }
      bound.receive
      begin
        first = MCPTestClient.new
        first.initialize_session

        second = MCPTestClient.new(URI.parse("http://127.0.0.1:#{MCP_PORT + 1}/mcp"))
        second.initialize_session
        first.call("open_toolbox", {name: "mcp_widgets"})["isError"].should be_false
        second.tool_names.should eq first.tool_names
        second.call("call_read_only", {name: "mcp_widgets_show", arguments: {"id" => 2, "X-Tenant" => "acme"}})["structuredContent"]["body"]["name"].should eq "widget-2-acme"
      ensure
        other.close
      end
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
      response = HTTP::Client.post(MCP_URI, headers: headers, body: {jsonrpc: "2.0", id: 2, method: "ping"}.to_json)
      response.status_code.should eq 400
      error = JSON.parse(response.body)["error"]
      error["code"].should eq -32022
      error["data"]["requested"].should eq "1999-01-01"
      error["data"]["supported"].as_a.should eq [MODERN_VERSION, "2025-11-25", "2025-06-18", "2025-03-26"]
    end

    it "has no event stream or sessions to end" do
      client = MCPTestClient.new
      client.initialize_session
      HTTP::Client.get(MCP_URI, headers: client.headers(accept: "text/event-stream")).status_code.should eq 405
      HTTP::Client.delete(MCP_URI, headers: client.headers).status_code.should eq 405
    end
  end

  describe "2026-07-28" do
    meta = {
      "io.modelcontextprotocol/protocolVersion"    => MODERN_VERSION,
      "io.modelcontextprotocol/clientCapabilities" => {} of String => String,
    }
    # posts a message with the headers provided, returning the status and body
    raw_post = ->(message : Hash(String, JSON::Any), headers : HTTP::Headers) do
      response = HTTP::Client.post(MCP_URI, headers: headers, body: message.to_json)
      {response.status_code, JSON.parse(response.body.presence || "null")}
    end
    modern_headers = ->(method : String) do
      HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json, text/event-stream", "MCP-Protocol-Version" => MODERN_VERSION, "Mcp-Method" => method}
    end
    message = ->(method : String, params : Hash(String, JSON::Any)) do
      JSON.parse({jsonrpc: "2.0", id: 7, method: method, params: params}.to_json).as_h
    end
    with_meta = ->(params : Hash(String, JSON::Any)) do
      params.merge({"_meta" => JSON.parse(meta.to_json)})
    end

    it "serves requests without initializing" do
      client = MCPTestClient.new(modern: true)
      client.tool_names.should eq DEFAULT_TOOLS
      client.call("mcp_widgets_show", {"id" => 5, "X-Tenant" => "acme"})["structuredContent"]["body"]["name"].should eq "widget-5-acme"
      response = client.post({jsonrpc: "2.0", id: 3, method: "tools/list"})
      response.headers["Mcp-Session-Id"]?.should be_nil
      response.content_type.should eq "application/json"
    end

    it "discovers the server" do
      response = MCPTestClient.new(modern: true).initialize_session
      response["id"].should eq 1
      result = response["result"]
      result["resultType"].should eq "complete"
      result["supportedVersions"].as_a.should eq [MODERN_VERSION, "2025-11-25", "2025-06-18", "2025-03-26"]
      result["capabilities"]["tools"]["listChanged"].should be_false
      result["capabilities"]["prompts"]["listChanged"].should be_false
      result["capabilities"]["extensions"]["io.modelcontextprotocol/ui"].should eq JSON.parse("{}")
      result["instructions"].as_s.should contain "list_toolboxes"
      result["ttlMs"].should eq 300_000
      result["cacheScope"].should eq "public"
      result["serverInfo"]?.should be_nil
      info = result["_meta"]["io.modelcontextprotocol/serverInfo"]
      info["name"].should eq "action-controller"
      info["version"].should eq "1.0.0"
      info["icons"].as_a.size.should eq 1
    end

    it "describes the server and result type in every result" do
      client = MCPTestClient.new(modern: true)
      result = client.call("list_toolboxes")
      result["resultType"].should eq "complete"
      result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"].should eq "action-controller"
      result["ttlMs"]?.should be_nil
      result["isError"].should be_false

      # tool results with an empty object are still valid JSON
      endpoint = MCPTestClient.new(URI.parse("http://127.0.0.1:#{MCP_PORT}/mcp_account/acme/mcp"), modern: true)
      endpoint.request("tools/list").last["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"].should eq "mcp_account"
    end

    it "includes cache hints in lists and resource reads" do
      client = MCPTestClient.new(modern: true)
      ["tools/list", "prompts/list", "resources/list"].each do |method|
        result = client.request(method).last["result"]
        result["ttlMs"].should eq 300_000
        result["cacheScope"].should eq "public"
      end
      read = client.request("resources/read", {uri: "ui://bookings/card.html"}).last["result"]
      read["ttlMs"].should eq 300_000
      read["contents"][0]["text"].as_s.should contain "booking card"

      # results that depend on the user's credentials are private
      ActionController::MCPServer.cache_ttl = 1.minute
      begin
        with_mcp_auth(transport, authenticator: ->(_request : HTTP::Request) { true }) do
          result = client.request("tools/list").last["result"]
          result["ttlMs"].should eq 60_000
          result["cacheScope"].should eq "private"
        end
      ensure
        ActionController::MCPServer.cache_ttl = 5.minutes
      end
    end

    it "rejects requests missing the required _meta fields" do
      [
        {} of String => JSON::Any,
        {"_meta" => JSON.parse(%({"io.modelcontextprotocol/protocolVersion": "#{MODERN_VERSION}"}))},
        {"_meta" => JSON.parse(%({"io.modelcontextprotocol/protocolVersion": "#{MODERN_VERSION}", "io.modelcontextprotocol/clientCapabilities": "none"}))},
      ].each do |params|
        status, body = raw_post.call(message.call("tools/list", params), modern_headers.call("tools/list"))
        status.should eq 400
        body["error"]["code"].should eq -32602
      end
    end

    it "rejects unsupported versions" do
      params = with_meta.call({} of String => JSON::Any)
      params["_meta"].as_h["io.modelcontextprotocol/protocolVersion"] = JSON::Any.new("2099-01-01")
      headers = modern_headers.call("tools/list")
      headers["MCP-Protocol-Version"] = "2099-01-01"
      status, body = raw_post.call(message.call("tools/list", params), headers)
      status.should eq 400
      body["error"]["code"].should eq -32022
      body["error"]["data"].should eq JSON.parse({supported: [MODERN_VERSION, "2025-11-25", "2025-06-18", "2025-03-26"], requested: "2099-01-01"}.to_json)

      # a legacy version in _meta isn't a modern request
      params["_meta"].as_h["io.modelcontextprotocol/protocolVersion"] = JSON::Any.new("2025-11-25")
      headers["MCP-Protocol-Version"] = "2025-11-25"
      status, body = raw_post.call(message.call("tools/list", params), headers)
      status.should eq 400
      body["error"]["code"].should eq -32022
    end

    it "validates the routing headers against the body" do
      params = with_meta.call({} of String => JSON::Any)
      call = with_meta.call({"name" => JSON::Any.new("mcp_root_time"), "arguments" => JSON.parse("{}")})
      mismatch = ->(msg : Hash(String, JSON::Any), headers : HTTP::Headers) do
        status, body = raw_post.call(msg, headers)
        status.should eq 400
        body["error"]["code"].should eq -32020
      end

      # protocol version header missing or different
      headers = modern_headers.call("tools/list")
      headers.delete("MCP-Protocol-Version")
      mismatch.call(message.call("tools/list", params), headers)
      headers["MCP-Protocol-Version"] = "2025-11-25"
      mismatch.call(message.call("tools/list", params), headers)

      # method header missing or different
      headers = modern_headers.call("tools/list")
      headers.delete("Mcp-Method")
      mismatch.call(message.call("tools/list", params), headers)
      mismatch.call(message.call("tools/list", params), modern_headers.call("prompts/list"))

      # name header missing or different
      mismatch.call(message.call("tools/call", call), modern_headers.call("tools/call"))
      headers = modern_headers.call("tools/call")
      headers["Mcp-Name"] = "mcp_root_pixel"
      mismatch.call(message.call("tools/call", call), headers)
      headers = modern_headers.call("resources/read")
      headers["Mcp-Name"] = "ui://rooms/card.html"
      mismatch.call(message.call("resources/read", with_meta.call({"uri" => JSON::Any.new("ui://bookings/card.html")})), headers)

      # names can be base64 encoded
      headers = modern_headers.call("tools/call")
      headers["Mcp-Name"] = "=?base64?#{Base64.strict_encode("mcp_root_time")}?="
      status, body = raw_post.call(message.call("tools/call", call), headers)
      status.should eq 200
      body["result"]["structuredContent"]["body"].should eq "noon"

      headers["Mcp-Name"] = "=?base64?not base64?="
      mismatch.call(message.call("tools/call", call), headers)
    end

    it "treats a modern header without _meta as malformed" do
      status, body = raw_post.call(message.call("tools/list", {} of String => JSON::Any), modern_headers.call("tools/list"))
      status.should eq 400
      body["error"]["code"].should eq -32602
    end

    it "responds 404 to unknown and removed methods" do
      client = MCPTestClient.new(modern: true)
      ["ping", "does/not/exist", "logging/setLevel"].each do |method|
        response = client.post({jsonrpc: "2.0", id: 4, method: method})
        response.status_code.should eq 404
        JSON.parse(response.body)["error"]["code"].should eq -32601
      end
    end

    it "reports unknown resources as invalid params" do
      client = MCPTestClient.new(modern: true)
      error = client.request("resources/read", {uri: "ui://missing.html"}).last["error"]
      error["code"].should eq -32602
      error["message"].should eq "Resource not found: ui://missing.html"
    end

    it "acknowledges subscriptions, with nothing to notify" do
      client = MCPTestClient.new(modern: true)
      response = client.post({jsonrpc: "2.0", id: 9, method: "subscriptions/listen", params: {notifications: {toolsListChanged: true, resourceSubscriptions: ["ui://bookings/card.html"]}}})
      response.status_code.should eq 200
      response.content_type.should eq "text/event-stream"
      events = response.body.split("\n\n").compact_map do |event|
        data = event.lines.find(&.starts_with?("data: "))
        JSON.parse(data.lchop("data: ")) if data
      end
      events.size.should eq 2
      events[0]["method"].should eq "notifications/subscriptions/acknowledged"
      events[0]["params"]["notifications"].should eq JSON.parse("{}")
      events[0]["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"].should eq 9
      events[1]["id"].should eq 9
      events[1]["result"]["resultType"].should eq "complete"
      events[1]["result"]["_meta"]["io.modelcontextprotocol/subscriptionId"].should eq 9
    end

    it "accepts notifications" do
      client = MCPTestClient.new(modern: true)
      client.post({jsonrpc: "2.0", method: "notifications/cancelled", params: {requestId: 1}}).status_code.should eq 202
    end

    it "serves controller endpoints" do
      client = MCPTestClient.new(URI.parse("http://127.0.0.1:#{MCP_PORT}/mcp_account/acme/mcp"), modern: true)
      result = client.initialize_session["result"]
      result["instructions"].should eq "Account acme: call show to look up its widgets"
      result["capabilities"]["tools"]["listChanged"].should be_false
      client.tool_names.sort.should eq ["rename", "show"]
      client.call("show", {id: 3})["structuredContent"]["body"].should eq JSON.parse(%({"account":"acme","id":3}))
    end

    it "challenges unauthenticated requests" do
      with_mcp_auth(transport, authenticator: ->(request : HTTP::Request) { request.headers["Authorization"]? == "Bearer token" }) do
        client = MCPTestClient.new(modern: true)
        client.authorization = nil
        client.post({jsonrpc: "2.0", id: 1, method: "tools/list"}).status_code.should eq 401
        client.authorization = "Bearer token"
        client.tool_names.should eq DEFAULT_TOOLS
      end
    end
  end

  describe "toolboxes" do
    it "lists the same tools for every request" do
      client = MCPTestClient.new
      client.initialize_session
      client.tool_names.should eq DEFAULT_TOOLS
      client.call("open_toolbox", {name: "mcp_widgets"})["isError"].should be_false
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
      widgets["open"]?.should be_nil
      widgets["description"].as_s.should start_with "Manages widgets"
    end

    it "opens toolboxes without changing anything" do
      client = MCPTestClient.new
      client.initialize_session

      # no notifications, so a single JSON response even when SSE is accepted
      messages = client.request("tools/call", {name: "open_toolbox", arguments: {name: "mcp_widgets"}}, accept: "application/json, text/event-stream")
      messages.size.should eq 1
      messages[0]["result"]["content"][0]["text"].as_s.should contain "mcp_widgets_show"
    end

    it "has no close_toolbox tool" do
      client = MCPTestClient.new
      client.initialize_session
      client.tool_names.should_not contain "close_toolbox"
      error = client.request("tools/call", {name: "close_toolbox", arguments: {name: "mcp_widgets"}}).first["error"]
      error["message"].should eq "Unknown tool: close_toolbox"
    end

    it "reports unknown toolboxes as tool errors" do
      client = MCPTestClient.new
      client.initialize_session
      result = client.call("open_toolbox", {name: "nope"})
      result["isError"].should be_true
      result["content"][0]["text"].as_s.should contain "Unknown toolbox"
    end

    it "calls toolbox tools without opening the toolbox" do
      client = MCPTestClient.new
      client.initialize_session
      client.call("mcp_widgets_show", {"id" => 1, "X-Tenant" => "acme"})["structuredContent"]["body"]["name"].should eq "widget-1-acme"
    end

    it "lists card only tools, even in toolboxes" do
      description = ActionController::MCPServer::Description.new([
        ActionController::MCPServer::Toolbox.new("cards", "Cards", nil, [
          ActionController::MCPServer::Tool.new("cards_hidden", nil, "post", "/cards", [] of ActionController::MCPServer::ToolParam, nil, JSON.parse("{}"), visibility: ["card"]),
          ActionController::MCPServer::Tool.new("cards_show", nil, "get", "/cards", [] of ActionController::MCPServer::ToolParam, nil, JSON.parse("{}")),
        ]),
      ])
      original = ActionController::MCPServer.description
      ActionController::MCPServer.description = description
      begin
        client = MCPTestClient.new
        client.initialize_session
        client.tool_names.should eq ["list_toolboxes", "open_toolbox", "call_read_only", "call_tool", "cards_hidden"]
      ensure
        ActionController::MCPServer.description = original
      end
    end
  end

  describe "tool calls" do
    it "invokes routes with path, query and header arguments" do
      client = MCPTestClient.new
      client.initialize_session

      result = client.call("mcp_widgets_show", {"id" => JSON::Any.new(12_i64), "detailed" => JSON::Any.new(true), "X-Tenant" => JSON::Any.new("acme")})
      result["isError"].should be_false
      result["structuredContent"].should eq JSON.parse(%({"status":200,"body":{"name":"widget-12-acme","size":10}}))
      # the text is the same envelope, for clients that only pass text to the model
      JSON.parse(result["content"][0]["text"].as_s).should eq result["structuredContent"]
    end

    it "invokes routes with a request body" do
      client = MCPTestClient.new
      client.initialize_session

      result = client.call("mcp_widgets_create", {body: {name: "new", size: 3}})
      result["isError"].should be_false
      result["structuredContent"]["status"].should eq 201
      result["structuredContent"]["body"]["name"].should eq "new"
    end

    it "reports empty responses using the status" do
      client = MCPTestClient.new
      client.initialize_session

      result = client.call("mcp_widgets_destroy", {id: 4})
      result["isError"].should be_false
      result["content"][0]["text"].should eq %({"status":202})
      result["structuredContent"].should eq JSON.parse(%({"status":202}))
    end

    it "flags HTTP errors" do
      client = MCPTestClient.new
      client.initialize_session

      result = client.call("mcp_widgets_show", {id: "not-a-number"})
      result["isError"].should be_true

      result = client.call("mcp_widgets_show", {} of String => String)
      result["isError"].should be_true
      result["content"][0]["text"].as_s.should contain "missing required argument: id"
    end

    it "forwards authentication headers" do
      client = MCPTestClient.new
      client.initialize_session

      headers = client.headers(accept: "application/json")
      headers["Authorization"] = "Bearer wrong"
      response = HTTP::Client.post(MCP_URI, headers: headers, body: {jsonrpc: "2.0", id: 3, method: "tools/call", params: {name: "mcp_widgets_show", arguments: {id: 1}}}.to_json)
      result = JSON.parse(response.body)["result"]
      result["isError"].should be_true
      result["structuredContent"]["status"].should eq 401
    end
  end

  describe "call_tool proxy" do
    it "returns tool definitions when opening a toolbox" do
      client = MCPTestClient.new
      client.initialize_session

      result = client.call("open_toolbox", {name: "mcp_widgets"})
      contents = result["structuredContent"]
      contents["toolbox"].should eq "mcp_widgets"
      contents["status"]?.should be_nil
      show = contents["tools"].as_a.find! { |tool| tool["name"] == "mcp_widgets_show" }
      show["inputSchema"]["required"].as_a.should contain "id"
      show["annotations"]["readOnlyHint"].should be_true
      show["proxy"].should eq "call_read_only"
      contents["prompts"].as_a.should_not be_empty
      contents["usage"].as_s.should contain "call_tool"
      JSON.parse(result["content"][0]["text"].as_s).should eq contents

      # opening again returns the same definitions, for a model that lost track of them
      client.call("open_toolbox", {name: "mcp_widgets"})["structuredContent"].should eq contents
    end

    it "runs toolbox tools" do
      client = MCPTestClient.new
      client.initialize_session

      # opening the toolbox first isn't required
      result = client.call("call_tool", {name: "mcp_widgets_show", arguments: {"id" => 12, "X-Tenant" => "acme"}})
      result["isError"].should be_false
      result["structuredContent"].should eq JSON.parse(%({"status":200,"body":{"name":"widget-12-acme"}}))

      # the same result as calling it directly
      client.call("mcp_widgets_show", {"id" => 12, "X-Tenant" => "acme"}).should eq result

      # route errors come back as they would directly
      client.call("call_tool", {name: "mcp_widgets_show", arguments: {id: "not-a-number"}})["isError"].should be_true
    end

    it "runs root tools without opening a toolbox" do
      client = MCPTestClient.new
      client.initialize_session
      client.call("call_tool", {name: "mcp_root_time"})["structuredContent"]["body"].should eq "noon"
    end

    it "reports mistakes as tool errors" do
      client = MCPTestClient.new
      client.initialize_session

      missing = client.call("call_tool", {arguments: {} of String => String})
      missing["isError"].should be_true
      missing["content"][0]["text"].as_s.should contain "Missing the name"

      unknown = client.call("call_tool", {name: "nope"})
      unknown["isError"].should be_true
      unknown["content"][0]["text"].as_s.should contain "Unknown tool"

      # meta tools aren't proxied
      meta = client.call("call_tool", {name: "open_toolbox", arguments: {name: "mcp_widgets"}})
      meta["isError"].should be_true
    end

    it "runs only read only tools with call_read_only" do
      client = MCPTestClient.new
      client.initialize_session
      # browsing toolboxes doesn't change data
      %w(list_toolboxes open_toolbox).each do |name|
        client.tools.find!(&.["name"].==(name))["annotations"]["readOnlyHint"].should be_true
      end
      client.tools.find!(&.["name"].==("call_read_only"))["annotations"]["readOnlyHint"].should be_true
      client.tools.find!(&.["name"].==("call_tool"))["annotations"]["readOnlyHint"].should be_false

      client.call("call_read_only", {name: "mcp_widgets_colours"})["structuredContent"]["body"].should eq JSON.parse(%(["red","green"]))

      destroy = client.call("call_read_only", {name: "mcp_widgets_destroy", arguments: {id: 4}})
      destroy["isError"].should be_true
      destroy["content"][0]["text"].should eq "Tool mcp_widgets_destroy can change data, run it with call_tool"
      client.call("call_tool", {name: "mcp_widgets_destroy", arguments: {id: 4}})["structuredContent"]["status"].should eq 202

      # call_tool runs read only tools too
      client.call("call_tool", {name: "mcp_widgets_colours"})["isError"].should be_false
    end

    it "names the proxy for each tool, honouring read_only overrides" do
      client = MCPTestClient.new
      client.initialize_session
      tools = client.call("open_toolbox", {name: "mcp_read_only"})["structuredContent"]["tools"].as_a
      search = tools.find!(&.["name"].==("mcp_read_only_search"))
      touch = tools.find!(&.["name"].==("mcp_read_only_touch"))

      search["proxy"].should eq "call_read_only"
      search["annotations"].should eq JSON.parse(%({"readOnlyHint":true}))
      touch["proxy"].should eq "call_tool"
      touch["annotations"]["readOnlyHint"].should be_false

      client.call("call_read_only", {name: "mcp_read_only_search", arguments: {body: "blue"}})["structuredContent"]["body"].should eq JSON.parse(%(["found blue"]))
      client.call("call_read_only", {name: "mcp_read_only_touch"})["isError"].should be_true
      client.call("call_tool", {name: "mcp_read_only_touch"})["structuredContent"]["body"].should eq "touched"

      # the same hints when listed directly, see "can be disabled"
      ActionController::MCPServer.tool_proxy = false
      begin
        listed = client.tools
        listed.find!(&.["name"].==("mcp_read_only_search"))["annotations"]["readOnlyHint"].should be_true
        listed.find!(&.["name"].==("mcp_read_only_touch"))["annotations"]["readOnlyHint"].should be_false
        listed.find!(&.["name"].==("mcp_read_only_touch"))["proxy"]?.should be_nil
      ensure
        ActionController::MCPServer.tool_proxy = true
      end
    end

    it "can be disabled, listing every tool instead of toolboxes" do
      ActionController::MCPServer.tool_proxy = false
      begin
        client = MCPTestClient.new
        result = client.initialize_session["result"]
        result["instructions"]?.should be_nil
        names = client.tool_names
        # the root tools come first
        names.first(DEFAULT_TOOLS.size - 4).should eq DEFAULT_TOOLS[4..]
        names.should contain "mcp_widgets_show"
        names.should contain "mcp_ui_summary"
        %w(list_toolboxes open_toolbox call_tool call_read_only).each do |meta|
          names.should_not contain meta
          response = client.post({jsonrpc: "2.0", id: 9, method: "tools/call", params: {name: meta, arguments: {name: "mcp_root_time"}}}, "application/json")
          JSON.parse(response.body)["error"]["message"].should eq "Unknown tool: #{meta}"
        end
        client.call("mcp_widgets_show", {id: 1})["isError"].should be_false
      ensure
        ActionController::MCPServer.tool_proxy = true
      end
    end

    it "keeps custom instructions" do
      ActionController::MCPServer.instructions = "Widgets! #{ActionController::MCPServer.toolbox_instructions}"
      begin
        instructions = MCPTestClient.new.initialize_session["result"]["instructions"].as_s
        instructions.should start_with "Widgets! "
        instructions.should contain "call_tool"
      ensure
        ActionController::MCPServer.instructions = nil
      end
    end

    it "can omit instructions" do
      ActionController::MCPServer.instructions = ""
      begin
        MCPTestClient.new.initialize_session["result"]["instructions"]?.should be_nil
      ensure
        ActionController::MCPServer.instructions = nil
      end
    end
  end

  describe "controller endpoints" do
    account_uri = ->(account : String) { URI.parse("http://127.0.0.1:#{MCP_PORT}/mcp_account/#{account}/mcp") }

    it "describes endpoints, binding the base path params" do
      description = ActionController::MCPServer.description
      ActionController::MCPServer.endpoint_paths.select(&.starts_with?("/mcp_")).sort!.should eq ["/mcp_account/:account_id/mcp", "/mcp_shared/assistant"]

      endpoint = description.endpoint?("/mcp_account/:account_id/mcp").should_not be_nil
      endpoint.name.should eq "mcp_account"
      endpoint.bound.should eq ["account_id"]
      endpoint.instructions.should eq "Manages an account, call show to look up its widgets"
      endpoint.instructions_path.should eq "/mcp_account/:account_id/__mcp_instructions__"
      description.endpoint?("/mcp_shared/assistant").try(&.instructions_path).should be_nil
      endpoint.toolbox.tools.map(&.name).sort!.should eq ["rename", "show"]
      endpoint.toolbox.tools.all?(&.root?).should be_true
      show = endpoint.toolbox.tools.find!(&.name.==("show"))
      show.input_schema["properties"].as_h.keys.should eq ["id"]
      show.input_schema["required"].should eq JSON.parse(%(["id"]))
      endpoint.toolbox.prompts.map(&.name).should eq ["describe"]
      endpoint.toolbox.prompts.first.arguments.map(&.name).should eq ["tone"]

      # endpoint controllers are hidden from the global server, unless `hide: false`
      description.toolbox?("mcp_account").should be_nil
      description.toolbox?("mcp_shared").should_not be_nil
      description.endpoint?("/mcp_shared/assistant").should_not be_nil

      # round trips, and older files without endpoints still load
      ActionController::MCPServer::Description.from_yaml(description.to_yaml).endpoint?("/mcp_account/:account_id/mcp").should_not be_nil
      ActionController::MCPServer::Description.from_yaml("toolboxes: []").endpoints.should be_empty
    end

    it "serves the controller's tools directly" do
      client = MCPTestClient.new(account_uri.call("acme"))
      result = client.initialize_session["result"]
      result["serverInfo"]["name"].should eq "mcp_account"
      result["instructions"].should eq "Account acme: call show to look up its widgets"
      result["capabilities"]["tools"]["listChanged"].should be_false

      client.tool_names.sort.should eq ["rename", "show"]
      client.tools.find!(&.["name"].==("show"))["inputSchema"]["properties"].as_h.keys.should eq ["id"]

      # the account comes from the URL, not the model
      client.call("show", {id: 3, account_id: "other"})["structuredContent"]["body"].should eq JSON.parse(%({"account":"acme","id":3}))
      client.call("rename", {body: "Acme Ltd"})["structuredContent"]["body"].should eq "acme is now Acme Ltd"

      prompt = client.request("prompts/get", {name: "describe", arguments: {tone: "casual"}}).last["result"]
      prompt["messages"][0]["content"]["text"].should eq "Describe account acme in a casual tone"
    end

    it "builds the instructions for each session" do
      ["acme", "globex"].each do |account|
        MCPTestClient.new(account_uri.call(account)).initialize_session["result"]["instructions"].should eq "Account #{account}: call show to look up its widgets"
      end

      # endpoints without an instructions method use the controller's doc comment
      shared = MCPTestClient.new(URI.parse("http://127.0.0.1:#{MCP_PORT}/mcp_shared/assistant"))
      shared.initialize_session["result"]["instructions"]?.should be_nil

      # it's not an HTTP route, a tool or a prompt
      HTTP::Client.get("http://127.0.0.1:#{MCP_PORT}/mcp_account/acme/__mcp_instructions__").status_code.should eq 404
      client = MCPTestClient.new(account_uri.call("acme"))
      client.initialize_session
      client.tool_names.should_not contain "instructions"
      client.request("prompts/list").last["result"]["prompts"].as_a.map(&.["name"].as_s).should_not contain "instructions"
    end

    it "fails to initialize when the instructions can't be built" do
      response = HTTP::Client.post(account_uri.call("forbidden"), headers: HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}, body: MCP_INIT.to_json)
      response.status_code.should eq 200
      response.headers["Mcp-Session-Id"]?.should be_nil
      error = JSON.parse(response.body)["error"]
      error["code"].should eq -32600
      error["message"].as_s.should start_with "403 Forbidden"
    end

    it "challenges the client when the instructions respond with 401" do
      with_mcp_auth(transport, authenticator: ->(_request : HTTP::Request) { true }) do
        response = HTTP::Client.post(account_uri.call("unauthorized"), headers: HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json", "Authorization" => "Bearer token"}, body: MCP_INIT.to_json)
        response.status_code.should eq 401
        response.headers["WWW-Authenticate"].should contain %(error="invalid_token")
        response.headers["Mcp-Session-Id"]?.should be_nil
      end
    end

    it "has no toolboxes or proxies" do
      client = MCPTestClient.new(account_uri.call("acme"))
      client.initialize_session
      %w(list_toolboxes open_toolbox call_tool secret mcp_widgets_colours).each do |name|
        response = client.post({jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: name, arguments: {} of String => String}}, "application/json")
        JSON.parse(response.body)["error"]["message"].should eq "Unknown tool: #{name}"
      end
    end

    it "binds the path params of every request from its URL" do
      client = MCPTestClient.new(account_uri.call("acme"))
      client.initialize_session
      body = {jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: "show", arguments: {id: 3}}}.to_json
      response = HTTP::Client.post(account_uri.call("globex"), headers: client.headers("application/json"), body: body)
      JSON.parse(response.body)["result"]["structuredContent"]["body"]["account"].should eq "globex"
    end

    it "serves endpoints at a custom path" do
      client = MCPTestClient.new(URI.parse("http://127.0.0.1:#{MCP_PORT}/mcp_shared/assistant"))
      client.initialize_session
      client.tool_names.should eq ["ping"]
      client.call("ping")["structuredContent"]["body"].should eq "pong"
    end

    it "advertises the endpoint URL as the protected resource" do
      metadata = ->(_request : HTTP::Request) { ActionController::MCPServer::ResourceMetadata.new(["https://auth.example.com"]) }
      with_mcp_auth(transport, authenticator: ->(_request : HTTP::Request) { false }, metadata: metadata) do
        response = HTTP::Client.post(account_uri.call("acme"), headers: HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}, body: MCP_INIT.to_json)
        response.status_code.should eq 401
        metadata_url = "http://127.0.0.1:#{MCP_PORT}/.well-known/oauth-protected-resource/mcp_account/acme/mcp"
        response.headers["WWW-Authenticate"].should eq %(Bearer resource_metadata="#{metadata_url}")

        resource = JSON.parse(HTTP::Client.get(metadata_url).body)["resource"]
        resource.should eq "http://127.0.0.1:#{MCP_PORT}/mcp_account/acme/mcp"
      end
    end
  end

  describe "UI cards" do
    ui_tool = ->(client : MCPTestClient, name : String) { client.tools.find!(&.["name"].==(name)) }
    read = ->(client : MCPTestClient, uri : String) {
      response = client.post({jsonrpc: "2.0", id: 5, method: "resources/read", params: {uri: uri}}, "application/json")
      JSON.parse(response.body)
    }

    it "describes the card and visibility of tools" do
      client = MCPTestClient.new
      capabilities = client.initialize_session(ui: true)["result"]["capabilities"]
      capabilities["resources"].should eq JSON.parse("{}")
      capabilities["extensions"]["io.modelcontextprotocol/ui"].should eq JSON.parse("{}")

      show = ui_tool.call(client, "mcp_ui_show")
      uri = show["_meta"]["ui"]["resourceUri"].as_s
      uri.should match /^ui:\/\/bookings\/card\.html\?v=[0-9a-f]{12}$/
      show["_meta"]["ui/resourceUri"].should eq uri
      show["_meta"]["ui"]["visibility"]?.should be_nil

      check_in = ui_tool.call(client, "mcp_ui_check_in")
      check_in["_meta"]["ui"].should eq JSON.parse(%({"visibility": ["app"]}))
      check_in["_meta"]["ui/resourceUri"]?.should be_nil

      ui_tool.call(client, "mcp_widgets_colours")["_meta"]?.should be_nil

      resources = client.request("resources/list").last["result"]["resources"].as_a
      resources.map(&.["name"].as_s).sort!.should eq ["bookings/card.html", "rooms/card.html"]
      resources.all?(&.["mimeType"].==("text/html;profile=mcp-app")).should be_true
      resources.find!(&.["name"].==("bookings/card.html"))["uri"].should eq uri
    end

    it "describes cards to clients that don't advertise the extension" do
      # hosts that render cards don't always advertise it, those that can't ignore `_meta`
      client = MCPTestClient.new
      client.initialize_session["result"]["capabilities"]["resources"].should eq JSON.parse("{}")
      ui_tool.call(client, "mcp_ui_show")["_meta"]["ui"]["resourceUri"].as_s.should start_with "ui://bookings/card.html?v="
      ui_tool.call(client, "mcp_ui_check_in")["_meta"]["ui"]["visibility"].should eq JSON.parse(%(["app"]))
      client.request("resources/list").last["result"]["resources"].as_a.size.should eq 2

      # the text content is the fallback for hosts without cards
      result = client.call("mcp_ui_show", {id: 4})
      JSON.parse(result["content"][0]["text"].as_s)["body"].should eq JSON.parse(%({"id":4,"title":"Booking 4"}))
    end

    it "only describes cards when there's a UI folder" do
      ActionController::MCPServer.ui_base = nil
      begin
        client = MCPTestClient.new
        # resources are advertised for the resource templates, but not the cards extension
        client.initialize_session["result"]["capabilities"]["extensions"]?.should be_nil
        ui_tool.call(client, "mcp_ui_show")["_meta"]?.should be_nil
        client.request("resources/list").last["result"]["resources"].as_a.should be_empty
      ensure
        ActionController::MCPServer.ui_base = File.join(__DIR__, "cards")
      end
    end

    it "reads cards with their metadata" do
      client = MCPTestClient.new
      client.initialize_session(ui: true)
      uri = ui_tool.call(client, "mcp_ui_show")["_meta"]["ui"]["resourceUri"].as_s

      [uri, "ui://bookings/card.html"].each do |requested|
        content = read.call(client, requested)["result"]["contents"][0]
        content["uri"].should eq requested
        content["mimeType"].should eq "text/html;profile=mcp-app"
        content["text"].as_s.should contain %(<p id="booking">booking card</p>)
        content["_meta"]["ui"].should eq JSON.parse(%({"prefersBorder": true}))
      end

      # a sidecar overrides the default
      rooms = read.call(client, "ui://rooms/card.html")["result"]["contents"][0]
      rooms["_meta"]["ui"].should eq JSON.parse(%({"csp": {"connectDomains": ["https://api.example.com"]}, "prefersBorder": false}))
    end

    it "only reads cards in the UI folder" do
      client = MCPTestClient.new
      client.initialize_session(ui: true)
      ["ui://../mcp_spec.cr", "ui://bookings/../../spec_helper.cr", "ui:///etc/hosts", "ui://notes.txt", "ui://missing.html", "https://example.com/card.html"].each do |uri|
        error = read.call(client, uri)["error"]
        error["code"].should eq -32002
        error["message"].should eq "Resource not found: #{uri}"
      end
    end

    it "lets cards call card only tools" do
      client = MCPTestClient.new
      client.initialize_session(ui: true)
      client.call("mcp_ui_check_in", {id: 7})["structuredContent"]["body"].should eq JSON.parse(%({"id":7,"checked_in":true}))
    end

    it "versions cards by their content" do
      original = ActionController::MCPServer.ui_base
      dir = File.tempname("mcp-cards")
      Dir.mkdir_p(dir)
      begin
        ActionController::MCPServer.ui_base = dir
        File.write(File.join(dir, "card.html"), "<!DOCTYPE html><p>one</p>")
        first = ActionController::MCPServer::UI.versioned("ui://card.html")
        ActionController::MCPServer::UI.versioned("ui://card.html").should eq first

        File.write(File.join(dir, "card.html"), "<!DOCTYPE html><p>two</p>")
        File.touch(File.join(dir, "card.html"), Time.utc + 1.minute)
        ActionController::MCPServer::UI.versioned("ui://card.html").should_not eq first
      ensure
        ActionController::MCPServer.ui_base = original
        FileUtils.rm_rf(dir)
      end
    end

    it "makes card and card only tools root items unless root: false" do
      box = ActionController::MCPServer.description.toolbox?("mcp_ui").should_not be_nil
      box.tools.find!(&.name.==("mcp_ui_show")).root?.should be_true
      box.tools.find!(&.name.==("mcp_ui_check_in")).root?.should be_true
      box.tools.find!(&.name.==("mcp_ui_history")).root?.should be_false
      box.toolbox_tools.map(&.name).should eq ["mcp_ui_summary", "mcp_ui_history"]
    end

    it "stores cards in the description" do
      description = ActionController::MCPServer::Description.from_yaml(ActionController::MCPServer.description.to_yaml)
      box = description.toolbox?("mcp_ui").should_not be_nil
      box.tools.find!(&.name.==("mcp_ui_show")).ui.should eq "ui://bookings/card.html"
      box.tools.find!(&.name.==("mcp_ui_rooms")).ui.should eq "ui://rooms/card.html"
      box.tools.find!(&.name.==("mcp_ui_check_in")).visibility.should eq ["card"]
    end
  end

  describe "annotation options" do
    tool_json = ->(tool : ActionController::MCPServer::Tool) { JSON.parse(JSON.build { |json| tool.to_mcp_json(json, host: "example.com") }) }
    tool_named = ->(name : String) {
      ActionController::MCPServer.description.toolboxes.flat_map(&.tools).find!(&.name.==(name))
    }

    it "infers the behaviour from the HTTP verb" do
      tool_json.call(tool_named.call("mcp_widgets_show"))["annotations"].should eq JSON.parse(%({"readOnlyHint": true}))
      tool_json.call(tool_named.call("mcp_widgets_create"))["annotations"].should eq JSON.parse(%({"readOnlyHint": false}))
      tool_json.call(tool_named.call("mcp_widgets_destroy"))["annotations"].should eq JSON.parse(%({"readOnlyHint": false, "destructiveHint": true, "idempotentHint": true}))
      put = ActionController::MCPServer::Tool.new("put", nil, "put", "/", [] of ActionController::MCPServer::ToolParam, nil, JSON.parse("{}"))
      tool_json.call(put)["annotations"].should eq JSON.parse(%({"readOnlyHint": false, "idempotentHint": true}))
    end

    it "replaces the inferred behaviour" do
      email = tool_named.call("mcp_options_email")
      tool_json.call(email)["annotations"].should eq JSON.parse(%({"title": "Send an email", "readOnlyHint": false, "destructiveHint": false, "openWorldHint": true}))
      email.read_only?.should be_false

      templates = tool_named.call("mcp_options_templates")
      tool_json.call(templates)["annotations"].should eq JSON.parse(%({"readOnlyHint": true, "openWorldHint": false}))
      templates.proxy.should eq "call_read_only"

      # a POST search can be run by call_read_only
      client = MCPTestClient.new
      client.initialize_session
      client.call("call_read_only", {name: "mcp_read_only_search", arguments: {body: "x"}})["isError"].should be_false
    end

    it "titles tools and prompts" do
      json = tool_json.call(tool_named.call("mcp_options_email"))
      json["title"].should eq "Send an email"
      json["annotations"]["title"].should eq "Send an email"
      tool_json.call(tool_named.call("mcp_options_templates"))["title"]?.should be_nil

      client = MCPTestClient.new
      client.initialize_session
      prompt = client.request("prompts/list").last["result"]["prompts"].as_a.find!(&.["name"].==("mcp_options_draft"))
      prompt["title"].should eq "Draft an email"
    end

    it "resolves icons" do
      svg = "data:image/svg+xml;base64,#{Base64.strict_encode(File.read(File.join(__DIR__, "cards/icons/bell.svg")))}"
      tool_json.call(tool_named.call("mcp_options_email"))["icons"].should eq JSON.parse({
        {src: "https://example.com/mail.png", sizes: ["48x48"]},
        {src: "https://example.com/mail-dark.png", theme: "dark", mimeType: "image/png"},
      }.to_json)
      # the controller's icons are the default, files in ui_base are data URLs
      tool_json.call(tool_named.call("mcp_options_templates"))["icons"].should eq JSON.parse([{src: svg, sizes: ["any"]}].to_json)
      tool_json.call(tool_named.call("mcp_ui_summary"))["icons"].should eq JSON.parse(%([{"src": "data:image/png;base64,AAAA"}]))
      tool_json.call(tool_named.call("mcp_widgets_show"))["icons"]?.should be_nil

      client = MCPTestClient.new
      client.initialize_session
      toolbox = client.call("list_toolboxes")["structuredContent"]["toolboxes"].as_a.find!(&.["name"].==("mcp_options"))
      toolbox["icons"].should eq JSON.parse([{src: svg, sizes: ["any"]}].to_json)

      # paths relative to the host are resolved against the request's Host header
      prompt = client.request("prompts/list").last["result"]["prompts"].as_a.find!(&.["name"].==("mcp_root_greet"))
      prompt["icons"]?.should be_nil
    end

    it "icons the servers" do
      client = MCPTestClient.new
      client.initialize_session["result"]["serverInfo"]["icons"].should eq JSON.parse(%([{"src": "https://127.0.0.1:#{MCP_PORT}/logo.png", "sizes": ["48x48"]}]))

      svg = "data:image/svg+xml;base64,#{Base64.strict_encode(File.read(File.join(__DIR__, "cards/icons/bell.svg")))}"
      endpoint = MCPTestClient.new(URI.parse("http://127.0.0.1:#{MCP_PORT}/mcp_account/acme/mcp"))
      endpoint.initialize_session["result"]["serverInfo"]["icons"].should eq JSON.parse([{src: svg, sizes: ["any"]}].to_json)
    end

    it "keeps card only tools from the model" do
      client = MCPTestClient.new
      client.initialize_session
      summary = client.tools.find!(&.["name"].==("mcp_ui_check_in"))
      summary["_meta"]["ui"]["visibility"].should eq JSON.parse(%(["app"]))

      model = tool_json.call(tool_named.call("mcp_ui_summary"))
      model["_meta"]?.should be_nil
      JSON.parse(JSON.build { |json| tool_named.call("mcp_ui_summary").to_mcp_json(json, ui: true) })["_meta"]["ui"]["visibility"].should eq JSON.parse(%(["model"]))

      # the model can't reach card only tools through the proxy
      refused = client.call("call_tool", {name: "mcp_ui_check_in", arguments: {id: 1}})
      refused["isError"].should be_true
      refused["content"][0]["text"].as_s.should contain "Unknown tool"
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
      client.initialize_session["result"]["capabilities"]["prompts"]["listChanged"].should be_false
    end

    it "lists every prompt, root prompts first" do
      client = MCPTestClient.new
      client.initialize_session
      prompts = client.request("prompts/list").last["result"]["prompts"].as_a
      names = prompts.map(&.["name"].as_s)
      names.first(2).should eq ["mcp_widgets_review", "mcp_root_greet"]
      names.should contain "mcp_widgets_summarise"
      names.should contain "mcp_prompts_only_greeting"

      prompt = prompts.find!(&.["name"].==("mcp_widgets_summarise"))
      prompt["description"].should eq "summarise a widget for the user"
      prompt["arguments"].as_a.should eq [
        JSON.parse(%({"name":"id","required":true})),
        JSON.parse(%({"name":"tone","description":"the tone of the summary","required":false})),
      ]
    end

    it "renders single message prompts" do
      client = MCPTestClient.new
      client.initialize_session

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
        # credentials are present so the server can be initialized
        client = MCPTestClient.new
        client.authorization = "Bearer expired"
        client.initialize_session
        client.call("list_toolboxes")["isError"].should be_false

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
end
