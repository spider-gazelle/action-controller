require "./spec_helper"
require "./mcp_spec"

MCP_RESOURCES_PORT = 6_124
MCP_RESOURCES_URI  = URI.parse("http://127.0.0.1:#{MCP_RESOURCES_PORT}/mcp")

# posts the request on a raw socket so the response can be read as it streams, and
# the connection closed part way through
def mcp_stream(client : MCPTestClient, body, &)
  headers, payload = client.prepare(body)
  headers["Host"] = "127.0.0.1:#{MCP_RESOURCES_PORT}"
  socket = TCPSocket.new("127.0.0.1", MCP_RESOURCES_PORT)
  begin
    HTTP::Request.new("POST", "/mcp", headers, payload).to_io(socket)
    socket.flush
    HTTP::Client::Response.from_io(socket) do |response|
      yield response, socket
    end
  rescue IO::Error
    # the spec closed the socket
  ensure
    socket.close unless socket.closed?
  end
end

# the next JSON-RPC message on an event stream, skipping keep-alive comments. `nil`
# once the stream ends
def next_event(io : IO) : JSON::Any?
  data = nil
  while line = io.gets(chomp: true)
    if line.empty?
      return JSON.parse(data) if data
      next
    end
    data = line.lchop("data: ") if line.starts_with?("data: ")
  end
end

describe "MCP resources" do
  server = ActionController::Server.new(MCP_RESOURCES_PORT, "127.0.0.1")
  transport = ActionController::MCPServer.mount(server, "/mcp")

  # the watchers' change procs by widget id, and the ids no longer watched
  changes = {} of String => Proc(Nil)
  stopped = [] of String

  before_all do
    ActionController::MCPServer.description = ActionController::MCPServer.generate_description({} of String => ActionController::OpenAPI::KlassDoc)
    ActionController::MCPServer.keep_alive = 100.milliseconds
    ActionController::MCPServer.update_debounce = 200.milliseconds
    ActionController::MCPServer.watch("app://widgets/{id}/state") do |variables, _request, changed|
      changes[variables["id"]] = changed
      -> { stopped << variables["id"]; nil }
    end
    bound = Channel(Nil).new
    spawn { server.run { bound.send nil } }
    bound.receive
  end

  after_all do
    server.close
    ActionController::MCPServer.description = nil
    ActionController::MCPServer.keep_alive = 15.seconds
    ActionController::MCPServer.update_debounce = 250.milliseconds
    ActionController::MCPServer.watchers.clear
  end

  before_each do
    changes.clear
    stopped.clear
    McpResources.cancelled.clear
  end

  describe ActionController::MCPServer::URITemplate do
    it "matches path variables" do
      template = ActionController::MCPServer::URITemplate.new("app://widgets/{id}/state/{key}")
      template.path_variables.should eq ["id", "key"]
      template.match("app://widgets/12/state/power%20on").should eq({"id" => "12", "key" => "power on"})
      template.match("app://widgets/12/state").should be_nil
      template.match("app://widgets/12/34/state/power").should be_nil
      template.match("app://widgets/12/state/power?extra=1").should be_nil
    end

    it "matches query variables" do
      template = ActionController::MCPServer::URITemplate.new("app://widgets/{id}/logs{?seconds,level}")
      template.query_variables.should eq ["seconds", "level"]
      template.match("app://widgets/1/logs").should eq({"id" => "1"})
      template.match("app://widgets/1/logs?seconds=30&level=info").should eq({"id" => "1", "seconds" => "30", "level" => "info"})
      template.match("app://widgets/1/logs?other=30").should be_nil
    end

    it "rejects unsupported expressions" do
      expect_raises(ActionController::MCPServer::URITemplate::Error) { ActionController::MCPServer::URITemplate.new("app://{+path}") }
      expect_raises(ActionController::MCPServer::URITemplate::Error) { ActionController::MCPServer::URITemplate.new("app://{?query}/more") }
    end

    it "orders templates by specificity" do
      description = ActionController::MCPServer.description
      description.resource?("app://widgets/1/state").should_not be_nil
      tool, variables = description.resource?("app://widgets/1/notes?lang=fr").should_not be_nil
      tool.name.should eq "mcp_resources_notes"
      variables.should eq({"id" => "1", "lang" => "fr"})
    end
  end

  describe "description" do
    it "describes resource templates" do
      tools = ActionController::MCPServer.description.toolbox?("mcp_resources").should_not(be_nil).tools
      state = tools.find!(&.name.==("mcp_resources_state"))
      state.resource.should eq "app://widgets/{id}/state"
      state.mime_type.should eq "application/json"
      state.subscribe?.should be_true
      state.cache_ttl.should eq 0
      logs = tools.find!(&.name.==("mcp_resources_logs"))
      logs.long_running?.should be_true
      logs.max_bytes.should eq 64
    end

    it "round trips through YAML" do
      yaml = ActionController::MCPServer.description.to_yaml
      parsed = ActionController::MCPServer::Description.from_yaml(yaml)
      parsed.resource?("app://widgets/1/logs?lines=2").should_not be_nil
      parsed.subscriptions?.should be_true
    end
  end

  describe "resources" do
    it "advertises subscriptions to modern clients only" do
      modern = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      modern.initialize_session["result"]["capabilities"]["resources"]["subscribe"].should be_true
      legacy = MCPTestClient.new(MCP_RESOURCES_URI)
      legacy.initialize_session["result"]["capabilities"]["resources"]["subscribe"]?.should be_nil
    end

    it "lists resource templates" do
      client = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      result = client.request("resources/templates/list").last["result"]
      result["ttlMs"].as_i64.should be > 0
      result["cacheScope"].should eq "public"
      templates = result["resourceTemplates"].as_a.select(&.["name"].as_s.starts_with?("mcp_resources"))
      templates.map(&.["uriTemplate"].as_s).sort!.should eq ["app://widgets/{id}/logs{?lines,delay_ms}", "app://widgets/{id}/notes{?lang}", "app://widgets/{id}/state"]
      state = templates.find!(&.["name"].==("mcp_resources_state"))
      state["mimeType"].should eq "application/json"
      state["description"].as_s.should_not be_empty
    end

    it "reads a resource" do
      client = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      result = client.request("resources/read", {uri: "app://widgets/1/state"}).last["result"]
      result["ttlMs"].should eq 0
      contents = result["contents"].as_a
      contents.size.should eq 1
      contents[0]["uri"].should eq "app://widgets/1/state"
      contents[0]["mimeType"].should eq "application/json"
      JSON.parse(contents[0]["text"].as_s).should eq JSON.parse(%({"power":true}))
    end

    it "reads a resource with query variables" do
      client = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      contents = client.request("resources/read", {uri: "app://widgets/7/notes?lang=fr"}).last["result"]["contents"][0]
      contents["text"].should eq "notes for 7 in fr"
      contents["mimeType"].should eq "text/plain"
    end

    it "reports unreadable resources" do
      client = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      missing = client.request("resources/read", {uri: "app://widgets/missing/state"}).last["error"]
      missing["code"].should eq -32602
      missing["message"].should eq "Resource not found: app://widgets/missing/state"
      client.request("resources/read", {uri: "app://widgets/secret/state"}).last["error"]["message"].as_s.should start_with "403"
      client.request("resources/read", {uri: "app://gadgets/1"}).last["error"]["code"].should eq -32602

      legacy = MCPTestClient.new(MCP_RESOURCES_URI)
      legacy.initialize_session
      legacy.request("resources/read", {uri: "app://widgets/missing/state"}).last["error"]["code"].should eq -32002
    end
  end

  describe "long running" do
    it "returns the result as JSON to clients that don't accept event streams" do
      client = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      response = client.post({jsonrpc: "2.0", id: 3, method: "resources/read", params: {uri: "app://widgets/1/logs?lines=2"}}, accept: "application/json")
      response.content_type.should eq "application/json"
      result = JSON.parse(response.body)["result"]
      result["resultType"].should eq "complete"
      result["contents"][0]["text"].should eq "line 1\nline 2\n"
      result["contents"][0]["mimeType"].should eq "text/plain"
      result["contents"][0]["_meta"]?.should be_nil
    end

    it "truncates the response at max_bytes" do
      client = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      result = client.request("resources/read", {uri: "app://widgets/1/logs?lines=40"}).last["result"]
      text = result["contents"][0]["text"].as_s
      text.bytesize.should be <= 64
      text.should start_with "line 1\nline 2\n"
      result["contents"][0]["_meta"]["truncated"].should be_true
    end

    it "streams progress before the result" do
      client = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      response = client.post({jsonrpc: "2.0", id: 4, method: "resources/read", params: {uri: "app://widgets/1/logs?lines=3&delay_ms=50", _meta: {progressToken: "logs"}}})
      response.content_type.should eq "text/event-stream"
      response.headers["X-Accel-Buffering"].should eq "no"
      events = response.body.split("\n\n").compact_map do |event|
        data = event.lines.find(&.starts_with?("data: "))
        JSON.parse(data.lchop("data: ")) if data
      end
      progress = events[0...-1]
      progress.map(&.["method"].as_s).uniq!.should eq ["notifications/progress"]
      progress.map(&.["params"]["progress"].as_i).should eq [1, 2, 3]
      progress[0]["params"]["progressToken"].should eq "logs"
      progress[0]["params"]["total"].should eq 3
      events.last["id"].should eq 4
      events.last["result"]["contents"][0]["text"].should eq "line 1\nline 2\nline 3\n"
    end

    it "runs long running tools" do
      client = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      result = client.call("call_read_only", {name: "mcp_resources_logs", arguments: {id: "1", lines: 2}})
      result["isError"].should be_false
      envelope = JSON.parse(result["content"][0]["text"].as_s)
      envelope["status"].should eq 200
      envelope["body"].should eq "line 1\nline 2\n"
    end

    it "cancels the route when the client disconnects" do
      client = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      mcp_stream(client, {jsonrpc: "2.0", id: 5, method: "resources/read", params: {uri: "app://widgets/cancel/logs?lines=1000&delay_ms=20", _meta: {progressToken: 1}}}) do |response, socket|
        response.content_type.should eq "text/event-stream"
        next_event(response.body_io).should_not be_nil
        socket.close
      end
      10.times do
        break unless McpResources.cancelled.empty?
        sleep 100.milliseconds
      end
      McpResources.cancelled.should eq ["cancel"]
    end
  end

  describe "subscriptions" do
    it "acknowledges and notifies the resources that can be read" do
      client = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      uris = ["app://widgets/1/state", "app://widgets/secret/state", "app://widgets/missing/state", "app://widgets/1/notes", "ui://unknown.html"]
      mcp_stream(client, {jsonrpc: "2.0", id: 6, method: "subscriptions/listen", params: {notifications: {toolsListChanged: true, resourceSubscriptions: uris}}}) do |response, socket|
        response.content_type.should eq "text/event-stream"
        body = response.body_io
        ack = next_event(body).should_not be_nil
        ack["method"].should eq "notifications/subscriptions/acknowledged"
        ack["params"]["notifications"].should eq JSON.parse(%({"resourceSubscriptions": ["app://widgets/1/state"]}))
        ack["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"].should eq 6
        changes.keys.should eq ["1"]

        # a burst of changes is coalesced
        3.times { changes["1"].call }
        update = next_event(body).should_not be_nil
        update["method"].should eq "notifications/resources/updated"
        update["params"]["uri"].should eq "app://widgets/1/state"
        update["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"].should eq 6

        changes["1"].call
        next_event(body).should_not be_nil
        socket.close
      end

      10.times do
        break unless stopped.empty?
        changes["1"]?.try &.call
        sleep 100.milliseconds
      end
      stopped.should eq ["1"]
    end

    it "debounces updates" do
      client = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      mcp_stream(client, {jsonrpc: "2.0", id: 7, method: "subscriptions/listen", params: {notifications: {resourceSubscriptions: ["app://widgets/1/state"]}}}) do |response, socket|
        body = response.body_io
        next_event(body)
        changes["1"].call
        first = Time.instant
        next_event(body)
        changes["1"].call
        next_event(body)
        (Time.instant - first).should be >= 150.milliseconds
        socket.close
      end

      # the disconnect is noticed on the next keep-alive
      20.times do
        break unless stopped.empty?
        sleep 50.milliseconds
      end
      stopped.should eq ["1"]
    end

    it "completes the subscription when the listen timeout expires" do
      ActionController::MCPServer.listen_timeout = 300.milliseconds
      client = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      response = client.post({jsonrpc: "2.0", id: 8, method: "subscriptions/listen", params: {notifications: {resourceSubscriptions: ["app://widgets/1/state"]}}})
      events = response.body.split("\n\n").compact_map do |event|
        data = event.lines.find(&.starts_with?("data: "))
        JSON.parse(data.lchop("data: ")) if data
      end
      events.last["id"].should eq 8
      events.last["result"]["resultType"].should eq "complete"
      events.last["result"]["_meta"]["io.modelcontextprotocol/subscriptionId"].should eq 8
      stopped.should eq ["1"]
    ensure
      ActionController::MCPServer.listen_timeout = nil
    end

    it "completes open subscriptions on close" do
      client = MCPTestClient.new(MCP_RESOURCES_URI, modern: true)
      mcp_stream(client, {jsonrpc: "2.0", id: 9, method: "subscriptions/listen", params: {notifications: {resourceSubscriptions: ["app://widgets/1/state"]}}}) do |response, _socket|
        body = response.body_io
        next_event(body)
        transport.close_subscriptions
        result = next_event(body).should_not be_nil
        result["id"].should eq 9
        result["result"]["resultType"].should eq "complete"
      end
      stopped.should eq ["1"]
    end
  end
end
