require "json"
require "yaml"
require "./open_api"
require "./router"

# Exposes the application's annotated routes as an [MCP](https://modelcontextprotocol.io) server
# using the Streamable HTTP transport.
#
# Controllers are presented as toolboxes and their routes as tools. To keep the
# model's context lean a session starts with these tools, plus any root tools:
#
# * `list_toolboxes` lists the controllers and their descriptions
# * `open_toolbox(name)` adds the controller's routes to the session's tool set
# * `close_toolbox(name)` removes them again
# * `call_read_only(name, arguments)` and `call_tool(name, arguments)` run tools from open
#   toolboxes, for clients that don't refresh their tools (when `tool_proxy` is enabled)
#
# Controllers can also be served as their own MCP server (`@[AC::MCP(endpoint: true)]`),
# and tools can render MCP Apps cards (`@[AC::MCP(ui:)]`), see `ActionController::MCP`.
#
# Tool calls are dispatched in-process through the application router, so
# filters, authentication and error handlers apply exactly as they would for a
# regular request.
#
# ```
# require "action-controller/mcp"
#
# server = ActionController::Server.new
# ActionController::MCPServer.mount(server, "/mcp")
# server.run
# ```
#
# Tool descriptions are extracted from the source code comments, so they need to
# be generated at build time and shipped alongside the binary:
#
# ```
# ActionController::MCPServer.write_description("mcp.yml")
# ```
#
# the file is lazily loaded from `description_path` the first time it is needed.
# Routes can be excluded using `@[AC::MCP(hide: true)]`
module ActionController::MCPServer
  extend self

  # :nodoc:
  Log = ::Log.for("action-controller.mcp")

  # supported protocol versions, newest first
  PROTOCOL_VERSIONS = {"2025-11-25", "2025-06-18", "2025-03-26"}

  DEFAULT_INSTRUCTIONS = <<-TEXT
    Tools are grouped into toolboxes. Call list_toolboxes to discover what is available,
    open_toolbox to load the tools in a toolbox and close_toolbox once you no longer need them.
    TEXT

  PROXY_INSTRUCTIONS = <<-TEXT
    #{DEFAULT_INSTRUCTIONS}
    open_toolbox returns the definitions of the tools it loads. If they don't appear in your
    available tools, run them with the tool named in their proxy field, passing the tool name
    and its arguments: call_read_only for tools that only read data, call_tool for the rest.
    TEXT

  # location of the MCP description file, generated using `write_description`
  class_property description_path : String = "mcp.yml"

  # reported to clients during initialization
  class_property server_name : String = "action-controller"

  # :ditto:
  class_property server_version : String = "1.0.0"

  # adds a `call_tool` meta tool that runs the tools in open toolboxes, for clients
  # that don't refresh their tools when notified with `tools/list_changed`
  class_property? tool_proxy : Bool = true

  # usage instructions provided to the model, `nil` uses `toolbox_instructions` and an
  # empty string provides none. Include `toolbox_instructions` when describing your domain
  class_setter instructions : String? = nil

  def self.instructions : String
    @@instructions || toolbox_instructions
  end

  # explains how to use toolboxes, taking `tool_proxy` into account
  def self.toolbox_instructions : String
    tool_proxy? ? PROXY_INSTRUCTIONS : DEFAULT_INSTRUCTIONS
  end

  # request headers copied from the MCP request to the route being invoked,
  # typically used for authentication
  class_property forward_headers : Array(String) = ["Authorization", "Cookie", "X-API-Key"]

  # browser origins permitted to connect, in addition to same origin requests.
  # `"*"` permits any origin
  class_property allowed_origins : Array(String) = [] of String

  # the folder of MCP Apps cards, `@[AC::MCP(ui: "bookings/card.html")]` renders
  # `<ui_base>/bookings/card.html`. Cards aren't served when `nil`
  class_property ui_base : String? = nil

  # the default `_meta.ui` of every card (CSP domains, border...), a card can override it
  # with a `.meta.json` file next to it, i.e. `bookings/card.meta.json`
  class_property ui_meta : UIMeta? = nil

  # the global server's icons, see `icon`
  class_getter icons : Array(JSON::Any) = [] of JSON::Any

  # adds an icon for the global server, `src` follows the `@[AC::Icon]` rules and every
  # other argument is passed through as is
  #
  # ```
  # ActionController::MCPServer.icon "icons/logo.svg", sizes: ["any"]
  # ActionController::MCPServer.icon "https://example.com/logo-dark.png", sizes: ["48x48"], theme: "dark"
  # ```
  def icon(src : String, **fields) : Nil
    @@icons << JSON.parse(fields.merge(src: src).to_json)
  end

  # sessions inactive for this period are discarded
  class_property session_timeout : Time::Span = 30.minutes

  # response headers left out of tool results, matched case-insensitively. An entry
  # ending in `*` matches by prefix. Everything else (`Link`, `X-Total-Count`,
  # `Content-Range`, `Location`, `ETag`, ...) is returned to the model
  class_property excluded_response_headers : Array(String) = [
    # noise
    "Date", "Content-Length", "X-Request-ID", "Content-Type", "Server", "Vary",
    "Cache-Control", "Pragma", "Expires", "Alt-Svc",
    # credentials
    "Set-Cookie", "Cookie", "Authorization", "WWW-Authenticate", "Proxy-*",
    # transport, the body is already decoded
    "Connection", "Keep-Alive", "Transfer-Encoding", "Content-Encoding", "Trailer", "Upgrade",
    # browser policy
    "Strict-Transport-Security", "Content-Security-Policy", "X-Frame-Options",
    "X-Content-Type-Options", "Referrer-Policy", "Access-Control-*",
  ]

  # :nodoc:
  # the response headers included in tool results
  def visible_headers(headers : HTTP::Headers) : Hash(String, String)
    excluded = excluded_response_headers.map(&.downcase)
    visible = {} of String => String
    headers.each do |name, values|
      lower = name.downcase
      next if excluded.any? { |pattern| pattern.ends_with?('*') ? lower.starts_with?(pattern.rchop('*')) : lower == pattern }
      visible[name] = values.join(", ")
    end
    visible
  end

  # authenticates MCP requests, returning `true` if the request is permitted.
  #
  # optional, see `auth_probe` for a simpler alternative
  class_property authenticator : Proc(HTTP::Request, Bool)? = nil

  # a route used to authenticate MCP requests, i.e. `/api/v1/users/current`.
  #
  # the route is requested in-process with the forwarded headers, a successful
  # (2xx) response indicates the request is authenticated
  class_property auth_probe : String? = nil

  # how long a successful authentication check is cached for
  class_property auth_cache_ttl : Time::Span = 1.minute

  # advertises the OAuth authorization server so MCP clients can obtain and
  # refresh access tokens. The request is provided for multi-tenant deployments
  class_property resource_metadata : Proc(HTTP::Request, ResourceMetadata)? = nil

  # authentication is optional and enabled when any of `authenticator`,
  # `auth_probe` or `resource_metadata` is configured
  def auth_enabled? : Bool
    !!(authenticator || auth_probe || resource_metadata)
  end

  @@description : Description? = nil
  @@description_lock = Mutex.new

  # the tool descriptions, lazily loaded from `description_path`.
  #
  # if the file doesn't exist the description is generated from the compiled
  # routes, however it will not include the documentation comments
  def description : Description
    @@description || @@description_lock.synchronize do
      @@description ||= load_description
    end
  end

  # replaces the current description, `nil` will reload it on next use
  def description=(description : Description?)
    @@description_lock.synchronize { @@description = description }
  end

  # generates the description, including source code comments, and saves it to a file
  def write_description(path : String = description_path) : Nil
    File.write(path, generate_description.to_yaml)
  end

  # mounts the MCP endpoint at the path provided.
  #
  # tool calls are dispatched via the router, typically `ActionController::Server`.
  # The OAuth protected resource metadata is served at `/.well-known/oauth-protected-resource<path>`
  #
  # `endpoints: true` also mounts the controller endpoints, `@[AC::MCP(endpoint: true)]`,
  # see `mount_endpoints`
  def mount(router : Router, path : String = "/mcp", endpoints : Bool = true) : Transport
    mount_endpoints(router) if endpoints
    mount_transport(router, Transport.new(router.route_handler, path))
  end

  # mounts a server for each controller annotated `@[AC::MCP(endpoint: true)]`
  def mount_endpoints(router : Router) : Array(Transport)
    endpoint_paths.map do |path|
      mount_transport(router, Transport.new(router.route_handler, path, endpoint: true))
    end
  end

  private def mount_transport(router : Router, transport : Transport) : Transport
    path = transport.path
    router.post(path) { |context, _head| transport.post(context) }
    router.get(path) { |context, head| transport.get(context, head) }
    router.delete(path) { |context, _head| transport.delete(context) }
    router.get(Transport::RESOURCE_METADATA_PATH + path) { |context, _head| transport.resource_metadata(context) }
    transport
  end

  # the path templates of the controller endpoints, `@[AC::MCP(endpoint: true)]`
  def endpoint_paths : Array(String)
    # expanded when the method is used, once all the routes are known
    {% begin %}
      concrete = [
        {% for klass in ::ActionController::Base::CONCRETE_CONTROLLERS.keys %}
          {{klass.stringify}},
        {% end %}
      ] of String

      paths = [
        {% for _route_key, details in ::ActionController::Route::Builder::OPENAPI_ROUTES %}
          {% if details[:mcp_endpoint] %}
            { {{ details[:controller] }}, {{ details[:mcp_endpoint] }} },
          {% end %}
        {% end %}
      ] of Tuple(String, String)

      paths.select { |(controller, _path)| concrete.includes?(controller) }.map(&.[1]).uniq!
    {% end %}
  end

  protected def load_description : Description
    if File.exists?(description_path)
      description = Description.from_yaml(File.read(description_path))
      missing = endpoint_paths.reject { |path| description.endpoint?(path) }
      return description if missing.empty?

      Log.warn { "#{description_path} is out of date, it's missing the endpoints #{missing.join(", ")}. Regenerate it using `ActionController::MCPServer.write_description`" }
      generate_description(docs: false)
    else
      Log.warn { "#{description_path} not found, tool descriptions will be missing. Generate it using `ActionController::MCPServer.write_description`" }
      generate_description(docs: false)
    end
  end
end

require "./mcp/*"
