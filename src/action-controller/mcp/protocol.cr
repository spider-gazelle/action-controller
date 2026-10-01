module ActionController::MCPServer
  # a JSON-RPC error response
  class RPCError < Exception
    PARSE_ERROR      = -32700
    INVALID_REQUEST  = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS   = -32602

    getter code : Int32

    def initialize(@code, message : String)
      super(message)
    end
  end

  # implements the MCP methods for an established session
  class Protocol
    TOOLS_CHANGED = %({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})

    TOOLBOX_ARGS = %({"type":"object","properties":{"name":{"type":"string","description":"the toolbox name, as returned by list_toolboxes"}},"required":["name"]})

    META_TOOLS = {
      %({"name":"list_toolboxes","description":"Lists the available toolboxes, each groups related tools","inputSchema":{"type":"object","properties":{}},"annotations":{"readOnlyHint":true}}),
      %({"name":"open_toolbox","description":"Adds the tools in a toolbox to your available tools","inputSchema":#{TOOLBOX_ARGS},"annotations":{"readOnlyHint":true,"idempotentHint":true}}),
      %({"name":"close_toolbox","description":"Removes the tools in a toolbox from your available tools, close toolboxes you are no longer using","inputSchema":#{TOOLBOX_ARGS},"annotations":{"readOnlyHint":true,"idempotentHint":true}}),
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
            end
          end
          json.field "serverInfo" do
            json.object do
              json.field "name", MCPServer.server_name
              json.field "version", MCPServer.server_version
            end
          end
          if instructions = MCPServer.instructions
            json.field "instructions", instructions
          end
        end
      end
    end

    # returns the JSON result of the request, any notifications generated are
    # appended to `emitted` for delivery before the result
    def handle(method : String, params : Hash(String, JSON::Any), session : Session, request : HTTP::Request, emitted : Array(String)) : String
      case method
      when "ping"       then "{}"
      when "tools/list" then list_tools(session)
      when "tools/call" then call_tool(params, session, request, emitted)
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
              session.open_toolboxes.each do |name|
                description.toolbox?(name).try &.tools.each(&.to_mcp_json(json))
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
        toolbox = toolbox_name.try { |box_name| description.toolbox?(box_name) }
        return MCPServer.tool_result("Unknown toolbox: #{toolbox_name.inspect}, use list_toolboxes to find the available toolboxes", error: true) unless toolbox

        if name == "open_toolbox"
          open_toolbox(session, toolbox, emitted)
        else
          close_toolbox(session, toolbox, emitted)
        end
      else
        found = description.tool?(name)
        raise RPCError.new(RPCError::INVALID_PARAMS, "Unknown tool: #{name}") unless found
        toolbox, tool = found
        raise RPCError.new(RPCError::INVALID_PARAMS, "Tool #{name} is not available, open the #{toolbox.name} toolbox first") unless session.open?(toolbox.name)

        @invoker.call(tool, arguments, request)
      end
    end

    private def list_toolboxes(session : Session) : String
      open = session.open_toolboxes
      toolboxes = JSON.build do |json|
        json.array do
          description.toolboxes.each do |toolbox|
            json.object do
              json.field "name", toolbox.name
              json.field "description", toolbox.description if toolbox.description
              json.field "tools", toolbox.tools.size
              json.field "open", open.includes?(toolbox.name)
            end
          end
        end
      end
      MCPServer.tool_result(toolboxes, structured: {"toolboxes" => JSON.parse(toolboxes)})
    end

    private def open_toolbox(session : Session, toolbox : Toolbox, emitted : Array(String)) : String
      return MCPServer.tool_result("Toolbox #{toolbox.name} is already open") unless session.open(toolbox.name)

      emitted << TOOLS_CHANGED
      MCPServer.tool_result("Opened toolbox #{toolbox.name}, tools added: #{toolbox.tools.join(", ", &.name)}")
    end

    private def close_toolbox(session : Session, toolbox : Toolbox, emitted : Array(String)) : String
      return MCPServer.tool_result("Toolbox #{toolbox.name} is not open") unless session.close(toolbox.name)

      emitted << TOOLS_CHANGED
      MCPServer.tool_result("Closed toolbox #{toolbox.name}")
    end
  end
end
