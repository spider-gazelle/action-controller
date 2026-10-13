require "ecr"
require "html"
require "../server"

module ActionController::MCPServer
  # mounts a browser test harness for the MCP Apps cards, intended for development.
  # Mount the MCP server first, the previewer connects to the path it was mounted at.
  # `mcp` overrides it, i.e. when a proxy serves the application under a prefix
  #
  # `GET <path>` lists the cards and the tools that render them, each tool has a page
  # (`<path>/tools/<name>`) with a form for its arguments that renders the card in a
  # mock MCP Apps host. The page is an MCP client of the global MCP server, so tool calls,
  # including those made by the card, use the same routes and authentication as any
  # other client.
  #
  # The tool pages accept query params, for linking and automated tests:
  #
  # * the tool arguments by name, `?id=42`, the card renders once all the required
  #   arguments are provided
  # * `viewport_size=desktop|tablet|mobile` and `theme=light|dark`
  # * `header.<Name>=<value>` request headers, i.e. `header.Authorization=Bearer%20...`
  #
  # The page's assets are only compiled in when this method is called, see the README
  # for excluding it from release builds.
  def mount_card_previewer(router : Router, path : String = "/mcp/card/preview", mcp : String? = nil, composition : Composition = composition_for(router)) : CardPreviewer
    mcp ||= mounted_path(router) || raise ArgumentError.new("mount the MCP server before the card previewer, `ActionController::MCPServer.mount(server, \"/mcp\")`, or provide its path with `mcp:`")
    previewer = CardPreviewer.new(path, mcp, composition)
    router.get(previewer.path) { |context, head| previewer.index(context, head) }
    router.get(previewer.tool_path(":name")) { |context, head| previewer.tool(context, head) }
    previewer
  end

  # :nodoc:
  # the pages of the card previewer, see `MCPServer.mount_card_previewer`
  class CardPreviewer
    # a card and the tools that render it
    record Card, uri : String, found : Bool, tools : Array(Tuple(Toolbox, Tool))

    # where the previewer is mounted
    getter path : String

    # the MCP server the pages connect to
    getter mcp : String

    def initialize(path : String, @mcp : String, @composition : Composition = Composition.default)
      @path = path.rchop('/').presence || "/"
    end

    # the page of a tool
    def tool_path(name : String) : String
      "#{@path.rchop('/')}/tools/#{name}"
    end

    def index(context : HTTP::Server::Context, head : Bool) : HTTP::Server::Context
      cards = self.cards
      card_tools = card_only_tools
      respond(context, head, HTTP::Status::OK, String.build { |io| ECR.embed "#{__DIR__}/previewer/index.ecr", io })
    end

    def tool(context : HTTP::Server::Context, head : Bool) : HTTP::Server::Context
      name = context.route_params["name"]? || ""
      found = description.tool?(name)
      unless found && found[1].ui
        message = found ? "#{name} doesn't render a card" : "unknown tool #{name}"
        return respond(context, head, HTTP::Status::NOT_FOUND, String.build { |io| ECR.embed "#{__DIR__}/previewer/not_found.ecr", io })
      end

      toolbox, tool = found
      config = tool_config(toolbox, tool)
      respond(context, head, HTTP::Status::OK, String.build { |io| ECR.embed "#{__DIR__}/previewer/tool.ecr", io })
    end

    # the cards, in the order their tools are described
    def cards : Array(Card)
      grouped = {} of String => Array(Tuple(Toolbox, Tool))
      description.toolboxes.each do |toolbox|
        toolbox.tools.each do |tool|
          next unless uri = tool.ui
          (grouped[uri] ||= [] of Tuple(Toolbox, Tool)) << {toolbox, tool}
        end
      end
      grouped.map { |uri, tools| Card.new(uri, !UI.resolve(uri).nil?, tools) }
    end

    # tools only cards can call, `visibility: :card`
    def card_only_tools : Array(Tuple(Toolbox, Tool))
      description.toolboxes.flat_map { |toolbox| toolbox.tools.reject(&.model?).map { |tool| {toolbox, tool} } }
    end

    private def description : Description
      MCPServer.description(@composition)
    end

    # the tool page's settings, embedded as JSON
    private def tool_config(toolbox : Toolbox, tool : Tool) : String
      {
        mcp:   @mcp,
        index: @path,
        tool:  {
          name:        tool.name,
          title:       tool.title,
          description: tool.description,
          verb:        tool.verb.upcase,
          path:        tool.path,
          inputSchema: tool.input_schema,
          ui:          tool.ui,
          found:       !tool.ui.try { |uri| UI.resolve(uri) }.nil?,
          toolbox:     toolbox.name,
          root:        tool.root?,
        },
      }.to_json.gsub("</", "<\\/")
    end

    private def respond(context : HTTP::Server::Context, head : Bool, status : HTTP::Status, body : String) : HTTP::Server::Context
      response = context.response
      response.status = status
      response.content_type = "text/html; charset=utf-8"
      response.headers["Cache-Control"] = "no-store"
      if head
        response.content_length = body.bytesize
      else
        response << body
      end
      context
    end

    private def h(value) : String
      HTML.escape(value.to_s)
    end

    # embedded at compile time, only when the previewer is mounted
    private def styles : String
      {{ read_file("#{__DIR__}/previewer/previewer.css") }}
    end

    private def script : String
      {{ read_file("#{__DIR__}/previewer/previewer.js") }}
    end
  end
end

class ActionController::Server
  # mounts the MCP Apps card previewer, see `ActionController::MCPServer.mount_card_previewer`.
  # Call it once the MCP server is mounted, from the `run` callback or before `run`
  #
  # ```
  # server.run do
  #   server.mount_mcp_card_previewer("/mcp/card/preview")
  # end
  # ```
  def mount_mcp_card_previewer(path : String = "/mcp/card/preview", mcp : String? = nil) : ActionController::MCPServer::CardPreviewer
    ActionController::MCPServer.mount_card_previewer(self, path, mcp, composition)
  end
end
