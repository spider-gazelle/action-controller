module ActionController::MCPServer
  # a JSON-RPC error response
  class RPCError < Exception
    PARSE_ERROR      = -32700
    INVALID_REQUEST  = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS   = -32602
    INTERNAL_ERROR   = -32603

    # MCP specific
    RESOURCE_NOT_FOUND           = -32002 # before 2026-07-28, now INVALID_PARAMS
    HEADER_MISMATCH              = -32020
    UNSUPPORTED_PROTOCOL_VERSION = -32022

    getter code : Int32

    def initialize(@code, message : String)
      super(message)
    end
  end

  # implements the MCP methods. Requests are independent, there are no sessions, so the
  # results only depend on the request and the path params bound from its URL
  class Protocol
    # methods whose results clients can cache, 2026-07-28 onwards
    CACHEABLE = {"server/discover", "tools/list", "prompts/list", "resources/list", "resources/read"}

    TOOLBOX_ARGS = %({"type":"object","properties":{"name":{"type":"string","description":"the toolbox name, as returned by list_toolboxes"}},"required":["name"]})

    META_TOOLS = {
      %({"name":"list_toolboxes","description":"Lists the available toolboxes, each groups related tools and prompts","inputSchema":{"type":"object","properties":{}},"annotations":{"readOnlyHint":true}}),
      %({"name":"open_toolbox","description":"Returns the definitions of the tools in a toolbox and the names of its prompts","inputSchema":#{TOOLBOX_ARGS},"annotations":{"readOnlyHint":true,"idempotentHint":true}}),
    }

    PROXY_ARGS = %({"type":"object","properties":{"name":{"type":"string","description":"the tool name, as returned by open_toolbox"},"arguments":{"type":"object","description":"the tool arguments, matching its inputSchema"}},"required":["name"]})

    PROXY_TOOLS = {
      %({"name":"call_read_only","description":"Runs a tool that only reads data (proxy: call_read_only) from a toolbox, as returned by open_toolbox","inputSchema":#{PROXY_ARGS},"annotations":{"readOnlyHint":true,"openWorldHint":false}}),
      %({"name":"call_tool","description":"Runs a tool that can change data (proxy: call_tool) from a toolbox, as returned by open_toolbox. Prefer call_read_only for tools that only read data","inputSchema":#{PROXY_ARGS},"annotations":{"readOnlyHint":false,"openWorldHint":false}}),
    }

    # `endpoint` is the path template of a controller endpoint, `nil` for the global server
    def initialize(@invoker : Invoker, @endpoint : String? = nil, @composition : Composition = Composition.default)
    end

    # a controller endpoint lists every tool directly, there are no toolboxes
    def flat? : Bool
      !@endpoint.nil?
    end

    private def endpoint : Endpoint
      path = @endpoint.as(String)
      MCPServer.description(@composition).endpoint?(path) || raise RPCError.new(RPCError::INTERNAL_ERROR, "No MCP description for #{path}")
    end

    # the `initialize` result for the negotiated protocol version, before 2026-07-28
    #
    # an endpoint's `instructions` method is run with the `bound` path params,
    # raising `RPCError` or `Unauthorized` if it fails
    def initialize_result(protocol_version : String, request : HTTP::Request? = nil, bound : Hash(String, String) = {} of String => String) : String
      instructions = server_instructions(request, bound)
      JSON.build do |json|
        json.object do
          json.field "protocolVersion", protocol_version
          json.field("capabilities") { capabilities(json) }
          json.field("serverInfo") { server_info(json, request) }
          if text = instructions.presence
            json.field "instructions", text
          end
        end
      end
    end

    # the `server/discover` result, the server info is in the result's `_meta`
    def discover_result(request : HTTP::Request? = nil, bound : Hash(String, String) = {} of String => String) : String
      instructions = server_instructions(request, bound)
      JSON.build do |json|
        json.object do
          json.field "supportedVersions", PROTOCOL_VERSIONS
          json.field("capabilities") { capabilities(json) }
          if text = instructions.presence
            json.field "instructions", text
          end
        end
      end
    end

    # the server's `Implementation`, its name, version and icons
    def server_info(json : JSON::Builder, request : HTTP::Request? = nil) : Nil
      json.object do
        json.field "name", flat? ? endpoint.name : MCPServer.server_name
        json.field "version", MCPServer.server_version
        Icons.to_json(json, flat? ? endpoint.toolbox.icons : MCPServer.icons, request.try { |req| host(req) })
      end
    end

    # the lists never change, toolboxes are opened by returning their tools
    private def capabilities(json : JSON::Builder) : Nil
      json.object do
        json.field("tools") { json.object { json.field "listChanged", false } }
        if description.prompts?
          json.field("prompts") { json.object { json.field "listChanged", false } }
        end
        if ui?
          json.field("resources") { json.object { } }
          json.field "extensions" do
            json.object do
              json.field(UI::EXTENSION) { json.object { } }
            end
          end
        end
      end
    end

    # returns the JSON result of the request. `modern` requests use 2026-07-28 or later
    def handle(method : String, params : Hash(String, JSON::Any), request : HTTP::Request, bound : Hash(String, String), modern : Bool = false) : String
      case method
      when "ping"
        raise RPCError.new(RPCError::METHOD_NOT_FOUND, "Method not found: #{method}") if modern
        "{}"
      when "server/discover" then discover_result(request, bound)
      when "tools/list"      then list_tools(request, bound)
      when "tools/call"      then call_tool(params, request, bound)
      when "prompts/list"    then list_prompts(request, bound)
      when "prompts/get"     then get_prompt(params, request, bound)
      when "resources/list"  then list_resources
      when "resources/read"  then read_resource(params, modern)
      else
        raise RPCError.new(RPCError::METHOD_NOT_FOUND, "Method not found: #{method}")
      end
    end

    # the endpoint's `instructions` method, otherwise its doc comment, or the global instructions
    private def server_instructions(request : HTTP::Request?, bound : Hash(String, String)) : String?
      return MCPServer.instructions unless flat?
      if (path = endpoint.instructions_path) && request
        return @invoker.instructions(path, request, bound)
      end
      endpoint.instructions
    end

    private def description : Description
      flat? ? endpoint.description : MCPServer.description(@composition)
    end

    # MCP Apps cards are described when there are cards to render. Every client is
    # sent the card metadata, hosts that can't render cards ignore it (and not every
    # host that can advertises the `io.modelcontextprotocol/ui` extension)
    private def ui? : Bool
      !MCPServer.ui_base.nil? && description.ui?
    end

    # the toolbox tools that are listed: card only tools, as cards call them via the
    # host, or every tool when there are no toolboxes
    private def listed_toolbox_tools : Array(Tool)
      tools = description.toolboxes.flat_map(&.toolbox_tools)
      MCPServer.tool_proxy? ? tools.reject(&.model?) : tools
    end

    # the cards of every tool
    private def list_resources : String
      cards = ui? ? description.toolboxes.flat_map(&.tools).compact_map(&.ui).uniq! : [] of String
      JSON.build do |json|
        json.object do
          json.field "resources" do
            json.array do
              cards.each do |uri|
                next unless UI.resolve(uri)
                json.object do
                  json.field "uri", UI.versioned(uri)
                  json.field "name", uri.lchop(UI::SCHEME)
                  json.field "mimeType", UI::MIME_TYPE
                end
              end
            end
          end
        end
      end
    end

    # a missing resource is invalid params from 2026-07-28
    private def read_resource(params : Hash(String, JSON::Any), modern : Bool) : String
      uri = params["uri"]?.try(&.as_s?)
      raise RPCError.new(RPCError::INVALID_PARAMS, "Missing resource uri") unless uri
      UI.read(uri) || raise RPCError.new(modern ? RPCError::INVALID_PARAMS : RPCError::RESOURCE_NOT_FOUND, "Resource not found: #{uri}")
    end

    # the host icon paths are relative to
    private def host(request : HTTP::Request) : String?
      request.headers["Host"]?
    end

    private def list_tools(request : HTTP::Request, bound : Hash(String, String)) : String
      JSON.build do |json|
        json.object do
          json.field "tools" do
            json.array do
              if !flat? && MCPServer.tool_proxy?
                META_TOOLS.each { |tool| json.raw tool }
                PROXY_TOOLS.each { |tool| json.raw tool }
              end
              tools = description.root_tools
              tools.concat(listed_toolbox_tools) unless flat?
              tools.each(&.to_mcp_json(json, ui: ui?, host: host(request), bound: bound))
            end
          end
        end
      end
    end

    private def call_tool(params : Hash(String, JSON::Any), request : HTTP::Request, bound : Hash(String, String)) : String
      name = params["name"]?.try(&.as_s?)
      raise RPCError.new(RPCError::INVALID_PARAMS, "Missing tool name") unless name
      arguments = params["arguments"]?.try(&.as_h?) || {} of String => JSON::Any
      return direct_call(name, arguments, request, bound) if flat? || !MCPServer.tool_proxy?

      case name
      when "list_toolboxes"
        list_toolboxes(request)
      when "open_toolbox"
        toolbox_name = arguments["name"]?.try(&.as_s?)
        toolbox = toolbox_name.try { |box_name| description.toolbox?(box_name) }.try { |box| box if box.openable? }
        return MCPServer.tool_result("Unknown toolbox: #{toolbox_name.inspect}, use list_toolboxes to find the available toolboxes", error: true) unless toolbox
        open_toolbox(toolbox, request, bound)
      when "call_tool", "call_read_only"
        proxy_call(arguments, request, bound, read_only: name == "call_read_only")
      else
        direct_call(name, arguments, request, bound)
      end
    end

    # any tool can be called directly, whether or not it's listed
    private def direct_call(name : String, arguments : Hash(String, JSON::Any), request : HTTP::Request, bound : Hash(String, String)) : String
      found = description.tool?(name)
      raise RPCError.new(RPCError::INVALID_PARAMS, "Unknown tool: #{name}") unless found
      @invoker.call(found[1], arguments, request, bound)
    end

    # runs a tool on behalf of the model, mistakes are tool errors so the model can
    # correct itself
    private def proxy_call(arguments : Hash(String, JSON::Any), request : HTTP::Request, bound : Hash(String, String), read_only : Bool) : String
      name = arguments["name"]?.try(&.as_s?)
      return MCPServer.tool_result("Missing the name of the tool to call", error: true) unless name
      tool_arguments = arguments["arguments"]?.try(&.as_h?) || {} of String => JSON::Any

      tool = description.tool?(name).try(&.[1]).try { |found| found if found.model? }
      return MCPServer.tool_result("Unknown tool: #{name.inspect}, use open_toolbox to find the available tools", error: true) unless tool
      return MCPServer.tool_result("Tool #{name} can change data, run it with call_tool", error: true) if read_only && !tool.read_only?

      @invoker.call(tool, tool_arguments, request, bound)
    end

    # every prompt, root prompts first. Users pick prompts, so they don't use the model's context
    private def list_prompts(request : HTTP::Request, bound : Hash(String, String)) : String
      JSON.build do |json|
        json.object do
          json.field "prompts" do
            json.array do
              description.root_prompts.each(&.to_mcp_json(json, host(request), bound: bound))
              description.toolboxes.each do |toolbox|
                toolbox.toolbox_prompts.each(&.to_mcp_json(json, host(request), bound: bound))
              end
            end
          end
        end
      end
    end

    private def get_prompt(params : Hash(String, JSON::Any), request : HTTP::Request, bound : Hash(String, String)) : String
      name = params["name"]?.try(&.as_s?)
      raise RPCError.new(RPCError::INVALID_PARAMS, "Missing prompt name") unless name
      arguments = params["arguments"]?.try(&.as_h?) || {} of String => JSON::Any

      found = description.prompt?(name)
      raise RPCError.new(RPCError::INVALID_PARAMS, "Unknown prompt: #{name}") unless found
      @invoker.get_prompt(found[1], arguments, request, bound)
    end

    private def list_toolboxes(request : HTTP::Request) : String
      toolboxes = JSON.build do |json|
        json.array do
          description.toolboxes.each do |toolbox|
            next unless toolbox.openable?
            json.object do
              json.field "name", toolbox.name
              json.field "description", toolbox.description if toolbox.description
              Icons.to_json(json, toolbox.icons, host(request))
              json.field "tools", toolbox.toolbox_tools.size
              json.field "prompts", toolbox.toolbox_prompts.size
            end
          end
        end
      end
      MCPServer.tool_result(toolboxes, structured: {"toolboxes" => JSON.parse(toolboxes)})
    end

    # returns the toolbox contents, nothing is stored so the toolbox is never "open"
    private def open_toolbox(toolbox : Toolbox, request : HTTP::Request, bound : Hash(String, String)) : String
      contents = JSON.build do |json|
        json.object do
          json.field "toolbox", toolbox.name
          json.field "tools" do
            json.array { toolbox.toolbox_tools.each(&.to_mcp_json(json, proxy: true, ui: ui?, host: host(request), bound: bound)) }
          end
          json.field "prompts" do
            json.array { toolbox.toolbox_prompts.each { |prompt| json.string prompt.name } }
          end
          json.field "usage", "run these tools with the tool named in their proxy field (call_read_only or call_tool), or call them directly if they are in your available tools"
        end
      end
      MCPServer.tool_result(contents, structured: JSON.parse(contents).as_h)
    end
  end
end
