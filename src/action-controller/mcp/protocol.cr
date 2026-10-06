module ActionController::MCPServer
  # a JSON-RPC error response
  class RPCError < Exception
    PARSE_ERROR      = -32700
    INVALID_REQUEST  = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS   = -32602
    INTERNAL_ERROR   = -32603

    getter code : Int32

    def initialize(@code, message : String)
      super(message)
    end
  end

  # implements the MCP methods for an established session
  class Protocol
    TOOLS_CHANGED   = %({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})
    PROMPTS_CHANGED = %({"jsonrpc":"2.0","method":"notifications/prompts/list_changed"})

    TOOLBOX_ARGS = %({"type":"object","properties":{"name":{"type":"string","description":"the toolbox name, as returned by list_toolboxes"}},"required":["name"]})

    META_TOOLS = {
      %({"name":"list_toolboxes","description":"Lists the available toolboxes, each groups related tools and prompts","inputSchema":{"type":"object","properties":{}},"annotations":{"readOnlyHint":true}}),
      %({"name":"open_toolbox","description":"Adds the tools and prompts in a toolbox to your available tools and prompts, returning the definitions of its tools","inputSchema":#{TOOLBOX_ARGS},"annotations":{"readOnlyHint":true,"idempotentHint":true}}),
      %({"name":"close_toolbox","description":"Removes the tools and prompts in a toolbox, close toolboxes you are no longer using","inputSchema":#{TOOLBOX_ARGS},"annotations":{"readOnlyHint":true,"idempotentHint":true}}),
    }

    PROXY_ARGS = %({"type":"object","properties":{"name":{"type":"string","description":"the tool name, as returned by open_toolbox"},"arguments":{"type":"object","description":"the tool arguments, matching its inputSchema"}},"required":["name"]})

    PROXY_TOOLS = {
      %({"name":"call_read_only","description":"Runs a tool that only reads data (proxy: call_read_only) from an open toolbox, use it when the tools returned by open_toolbox aren't in your available tools","inputSchema":#{PROXY_ARGS},"annotations":{"readOnlyHint":true,"openWorldHint":false}}),
      %({"name":"call_tool","description":"Runs a tool that can change data (proxy: call_tool) from an open toolbox, use it when the tools returned by open_toolbox aren't in your available tools. Prefer call_read_only for tools that only read data","inputSchema":#{PROXY_ARGS},"annotations":{"readOnlyHint":false,"openWorldHint":false}}),
    }

    def initialize(@invoker : Invoker)
    end

    # the `initialize` result for the negotiated protocol version
    def initialize_result(protocol_version : String) : String
      JSON.build do |json|
        json.object do
          json.field "protocolVersion", protocol_version
          json.field "capabilities" do
            json.object do
              json.field "tools" do
                json.object { json.field "listChanged", true }
              end
              if description.prompts?
                json.field "prompts" do
                  json.object { json.field "listChanged", true }
                end
              end
            end
          end
          json.field "serverInfo" do
            json.object do
              json.field "name", MCPServer.server_name
              json.field "version", MCPServer.server_version
            end
          end
          if instructions = MCPServer.instructions.presence
            json.field "instructions", instructions
          end
        end
      end
    end

    # returns the JSON result of the request, any notifications generated are
    # appended to `emitted` for delivery before the result
    def handle(method : String, params : Hash(String, JSON::Any), session : Session, request : HTTP::Request, emitted : Array(String)) : String
      case method
      when "ping"         then "{}"
      when "tools/list"   then list_tools(session)
      when "tools/call"   then call_tool(params, session, request, emitted)
      when "prompts/list" then list_prompts(session)
      when "prompts/get"  then get_prompt(params, session, request)
      else
        raise RPCError.new(RPCError::METHOD_NOT_FOUND, "Method not found: #{method}")
      end
    end

    private def description : Description
      MCPServer.description
    end

    private def list_tools(session : Session) : String
      JSON.build do |json|
        json.object do
          json.field "tools" do
            json.array do
              META_TOOLS.each { |tool| json.raw tool }
              PROXY_TOOLS.each { |tool| json.raw tool } if MCPServer.tool_proxy?
              description.root_tools.each(&.to_mcp_json(json))
              session.open_toolboxes.each do |name|
                description.toolbox?(name).try &.toolbox_tools.each(&.to_mcp_json(json))
              end
            end
          end
        end
      end
    end

    private def call_tool(params : Hash(String, JSON::Any), session : Session, request : HTTP::Request, emitted : Array(String)) : String
      name = params["name"]?.try(&.as_s?)
      raise RPCError.new(RPCError::INVALID_PARAMS, "Missing tool name") unless name
      arguments = params["arguments"]?.try(&.as_h?) || {} of String => JSON::Any

      case name
      when "list_toolboxes"
        list_toolboxes(session)
      when "open_toolbox", "close_toolbox"
        toolbox_name = arguments["name"]?.try(&.as_s?)
        toolbox = toolbox_name.try { |box_name| description.toolbox?(box_name) }.try { |box| box if box.openable? }
        return MCPServer.tool_result("Unknown toolbox: #{toolbox_name.inspect}, use list_toolboxes to find the available toolboxes", error: true) unless toolbox

        if name == "open_toolbox"
          open_toolbox(session, toolbox, emitted)
        else
          close_toolbox(session, toolbox, emitted)
        end
      when "call_tool", "call_read_only"
        raise RPCError.new(RPCError::INVALID_PARAMS, "Unknown tool: #{name}") unless MCPServer.tool_proxy?
        proxy_call(arguments, session, request, read_only: name == "call_read_only")
      else
        found = description.tool?(name)
        raise RPCError.new(RPCError::INVALID_PARAMS, "Unknown tool: #{name}") unless found
        toolbox, tool = found
        raise RPCError.new(RPCError::INVALID_PARAMS, "Tool #{name} is not available, open the #{toolbox.name} toolbox first") unless tool.root? || session.open?(toolbox.name)

        @invoker.call(tool, arguments, request)
      end
    end

    # runs a tool on behalf of a client that can't see it, mistakes are tool errors so
    # the model can correct itself
    private def proxy_call(arguments : Hash(String, JSON::Any), session : Session, request : HTTP::Request, read_only : Bool) : String
      name = arguments["name"]?.try(&.as_s?)
      return MCPServer.tool_result("Missing the name of the tool to call", error: true) unless name
      tool_arguments = arguments["arguments"]?.try(&.as_h?) || {} of String => JSON::Any

      found = description.tool?(name)
      return MCPServer.tool_result("Unknown tool: #{name.inspect}, use open_toolbox to find the available tools", error: true) unless found
      toolbox, tool = found
      return MCPServer.tool_result("Tool #{name} is not available, open the #{toolbox.name} toolbox first", error: true) unless tool.root? || session.open?(toolbox.name)
      return MCPServer.tool_result("Tool #{name} can change data, run it with call_tool", error: true) if read_only && !tool.read_only?

      @invoker.call(tool, tool_arguments, request)
    end

    private def list_prompts(session : Session) : String
      JSON.build do |json|
        json.object do
          json.field "prompts" do
            json.array do
              description.root_prompts.each(&.to_mcp_json(json))
              session.open_toolboxes.each do |name|
                description.toolbox?(name).try &.toolbox_prompts.each(&.to_mcp_json(json))
              end
            end
          end
        end
      end
    end

    private def get_prompt(params : Hash(String, JSON::Any), session : Session, request : HTTP::Request) : String
      name = params["name"]?.try(&.as_s?)
      raise RPCError.new(RPCError::INVALID_PARAMS, "Missing prompt name") unless name
      arguments = params["arguments"]?.try(&.as_h?) || {} of String => JSON::Any

      found = description.prompt?(name)
      raise RPCError.new(RPCError::INVALID_PARAMS, "Unknown prompt: #{name}") unless found
      toolbox, prompt = found
      raise RPCError.new(RPCError::INVALID_PARAMS, "Prompt #{name} is not available, open the #{toolbox.name} toolbox first") unless prompt.root? || session.open?(toolbox.name)

      @invoker.get_prompt(prompt, arguments, request)
    end

    private def list_toolboxes(session : Session) : String
      open = session.open_toolboxes
      toolboxes = JSON.build do |json|
        json.array do
          description.toolboxes.each do |toolbox|
            next unless toolbox.openable?
            json.object do
              json.field "name", toolbox.name
              json.field "description", toolbox.description if toolbox.description
              json.field "tools", toolbox.toolbox_tools.size
              json.field "prompts", toolbox.toolbox_prompts.size
              json.field "open", open.includes?(toolbox.name)
            end
          end
        end
      end
      MCPServer.tool_result(toolboxes, structured: {"toolboxes" => JSON.parse(toolboxes)})
    end

    # returns the toolbox contents, so clients that don't refresh their tools when
    # notified still learn what's available
    private def open_toolbox(session : Session, toolbox : Toolbox, emitted : Array(String)) : String
      opened = session.open(toolbox.name)
      notify_changes(toolbox, emitted) if opened

      contents = JSON.build do |json|
        json.object do
          json.field "toolbox", toolbox.name
          json.field "status", opened ? "opened" : "already open"
          json.field "tools" do
            json.array { toolbox.toolbox_tools.each(&.to_mcp_json(json, proxy: MCPServer.tool_proxy?)) }
          end
          json.field "prompts" do
            json.array { toolbox.toolbox_prompts.each { |prompt| json.string prompt.name } }
          end
          if MCPServer.tool_proxy?
            json.field "usage", "call these tools directly if they are in your available tools, otherwise run them with the tool named in their proxy field (call_read_only or call_tool)"
          end
        end
      end
      MCPServer.tool_result(contents, structured: JSON.parse(contents).as_h)
    end

    private def close_toolbox(session : Session, toolbox : Toolbox, emitted : Array(String)) : String
      return MCPServer.tool_result("Toolbox #{toolbox.name} is not open") unless session.close(toolbox.name)

      notify_changes(toolbox, emitted)
      MCPServer.tool_result("Closed toolbox #{toolbox.name}")
    end

    # emits the list changed notifications for the toolbox
    private def notify_changes(toolbox : Toolbox, emitted : Array(String)) : Nil
      emitted << TOOLS_CHANGED unless toolbox.toolbox_tools.empty?
      emitted << PROMPTS_CHANGED unless toolbox.toolbox_prompts.empty?
    end
  end
end
