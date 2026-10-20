require "json"
require "yaml"
require "./open_api"
require "./router"

# Exposes the application's annotated routes as an [MCP](https://modelcontextprotocol.io) server
# using the Streamable HTTP transport.
#
# Controllers are presented as toolboxes and their routes as tools. To keep the
# model's context lean only these tools are listed, plus any root tools:
#
# * `list_toolboxes` lists the controllers and their descriptions
# * `open_toolbox(name)` returns the definitions of the controller's tools
# * `call_read_only(name, arguments)` and `call_tool(name, arguments)` run the tools
#
# The server is stateless, there are no sessions, so requests can be served by any
# instance of the application. Both the 2026-07-28 protocol and the earlier versions,
# which start with `initialize`, are supported.
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

  # stateless protocol versions, where every request carries its version in `_meta`
  MODERN_VERSIONS = {"2026-07-28"}

  # protocol versions that start with `initialize`, newest first
  LEGACY_VERSIONS = {"2025-11-25", "2025-06-18", "2025-03-26"}

  # supported protocol versions, newest first
  PROTOCOL_VERSIONS = MODERN_VERSIONS + LEGACY_VERSIONS

  TOOLBOX_INSTRUCTIONS = <<-TEXT
    Tools are grouped into toolboxes. Call list_toolboxes to discover what is available and
    open_toolbox for the definitions of the tools in a toolbox. Run them with the tool named
    in their proxy field, passing the tool name and its arguments: call_read_only for tools
    that only read data, call_tool for the rest.
    TEXT

  # location of the MCP description file, generated using `write_description`
  class_property description_path : String = "mcp.yml"

  # reported to clients during initialization
  class_property server_name : String = "action-controller"

  # :ditto:
  class_property server_version : String = "1.0.0"

  # groups the tools into toolboxes, run by the `call_read_only` and `call_tool` meta
  # tools. When disabled every tool is listed
  class_property? tool_proxy : Bool = true

  # usage instructions provided to the model, `nil` uses `toolbox_instructions` and an
  # empty string provides none. Include `toolbox_instructions` when describing your domain
  class_setter instructions : String? = nil

  def self.instructions : String
    @@instructions || toolbox_instructions
  end

  # explains how to use toolboxes, empty when `tool_proxy` is disabled
  def self.toolbox_instructions : String
    tool_proxy? ? TOOLBOX_INSTRUCTIONS : ""
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

  # how long clients can cache the server description and lists (`ttlMs`), 2026-07-28 onwards
  class_property cache_ttl : Time::Span = 5.minutes

  # how often an SSE comment is sent on idle event streams, which keeps proxies from
  # timing them out and detects clients that have disconnected
  class_property keep_alive : Time::Span = 15.seconds

  # how long a `subscriptions/listen` stream stays open, `nil` keeps it open until the
  # client disconnects. The stream is then completed and clients listen again
  class_property listen_timeout : Time::Span? = nil

  # updates to a resource are sent at most once per period, clients read the resource
  # for its current state so bursts of changes are coalesced
  class_property update_debounce : Time::Span = 250.milliseconds

  # the maximum number of resources a single `subscriptions/listen` can subscribe to
  class_property max_subscriptions : Int32 = 100

  # watches a resource for changes, see `watch`. Called with the template variables, the
  # MCP request and a proc to call whenever the resource changes, it returns a proc that
  # stops watching
  alias Watcher = Proc(Hash(String, String), HTTP::Request, Proc(Nil), Proc(Nil))

  # the watchers of resource templates with `@[AC::MCP(subscribe: true)]`
  class_getter watchers : Hash(String, Watcher) = {} of String => Watcher

  # watches the resources of a template for changes, so clients can subscribe to them
  # using `subscriptions/listen`. The template must match a route annotated
  # `@[AC::MCP(resource: template, subscribe: true)]`.
  #
  # A client can only subscribe to resources it can read: the route is requested before
  # the watcher is called. The block is called once per subscription and returns a proc
  # that stops watching, called when the client disconnects
  #
  # ```
  # ActionController::MCPServer.watch("app://widgets/{id}") do |variables, _request, changed|
  #   subscription = Widget.on_change(variables["id"]) { changed.call }
  #   -> { subscription.cancel }
  # end
  # ```
  def watch(template : String, &block : Hash(String, String), HTTP::Request, Proc(Nil) -> Proc(Nil)) : Nil
    watchers[template] = block
  end

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

  @@descriptions = {} of Tuple(String, String) => Description
  @@description_lock = Mutex.new
  @@description_generation = Atomic(UInt64).new(0)

  # :nodoc:
  # Immutable snapshots keep warmed reads free of locks and catalog hashing.
  class CachedDescription
    getter generation : UInt64
    getter path : String
    getter description : Description

    def initialize(@generation, @path, @description)
    end
  end

  # the tool descriptions, lazily loaded from `description_path`.
  #
  # if the file doesn't exist the description is generated from the compiled
  # routes, however it will not include the documentation comments
  def description(composition : Composition = Composition.default) : Description
    path = description_path
    if cached = composition.mcp_description_cache.get(:acquire)
      if cached.generation == @@description_generation.get(:acquire) && cached.path == path
        return cached.description
      end
    end
    @@description_lock.synchronize do
      description = @@descriptions[{composition.signature, path}] ||= load_description(composition)
      composition.mcp_description_cache.set(CachedDescription.new(@@description_generation.get(:relaxed), path, description), :release)
      description
    end
  end

  # replaces the current description, `nil` will reload it on next use
  def description=(description : Description?)
    @@description_lock.synchronize do
      @@descriptions.clear
      @@descriptions[{Composition.default.signature, description_path}] = description if description
      @@description_generation.add(1, :release)
    end
  end

  # generates the description, including source code comments, and saves it to a file
  def write_description(path : String = description_path, composition : Composition = Composition.default) : Nil
    File.write(path, generate_description(composition: composition).to_yaml)
  end

  # mounts the MCP endpoint at the path provided.
  #
  # tool calls are dispatched via the router, typically `ActionController::Server`.
  # The OAuth protected resource metadata is served at `/.well-known/oauth-protected-resource<path>`
  #
  # `endpoints: true` also mounts the controller endpoints, `@[AC::MCP(endpoint: true)]`,
  # see `mount_endpoints`
  def mount(router : Router, path : String = "/mcp", endpoints : Bool = true, composition : Composition = composition_for(router)) : Transport
    declarations = endpoints ? controller_endpoints(composition) : [] of Tuple(String, String)
    validate_endpoints!(router, declarations + [{"global MCP", path}])
    declarations.each do |(_controller, endpoint_path)|
      mount_transport(router, Transport.new(router.route_handler, endpoint_path, endpoint: true, composition: composition))
    end
    transport = mount_transport(router, Transport.new(router.route_handler, path, composition: composition))
    @@mounted_lock.synchronize { @@mounted[router.route_handler.object_id] = path }
    transport
  end

  @@mounted = {} of UInt64 => String
  @@mounted_lock = Mutex.new

  # the path of the global MCP server mounted on the router, `nil` if there isn't one
  def mounted_path(router : Router) : String?
    @@mounted_lock.synchronize { @@mounted[router.route_handler.object_id]? }
  end

  # mounts a server for each controller annotated `@[AC::MCP(endpoint: true)]`
  def mount_endpoints(router : Router, composition : Composition = composition_for(router)) : Array(Transport)
    declarations = controller_endpoints(composition)
    validate_endpoints!(router, declarations)
    declarations.map do |(_controller, path)|
      mount_transport(router, Transport.new(router.route_handler, path, endpoint: true, composition: composition))
    end
  end

  private def composition_for(router : Router) : Composition
    if router.is_a?(Composition)
      router
    elsif router.responds_to?(:composition)
      router.composition
    else
      Composition.default
    end
  end

  private def mount_transport(router : Router, transport : Transport) : Transport
    path = transport.path
    router.post(path) { |context, _head| transport.post(context) }
    router.get(path) { |context, _head| transport.method_not_allowed(context) }
    router.delete(path) { |context, _head| transport.method_not_allowed(context) }
    router.get(Transport::RESOURCE_METADATA_PATH + path) { |context, _head| transport.resource_metadata(context) }
    transport
  end

  # the path templates of the controller endpoints, `@[AC::MCP(endpoint: true)]`
  def endpoint_paths(composition : Composition = Composition.default) : Array(String)
    controller_endpoints(composition).map(&.[1]).uniq!
  end

  private def controller_endpoints(composition : Composition) : Array(Tuple(String, String))
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

      composition.placements.flat_map do |placement|
        paths.select { |(controller, _path)| controller == placement.controller.name && concrete.includes?(controller) }.map { |(_, path)| {"#{placement.controller.name}@#{placement.base}", placement.path(path)} }
      end.uniq!
    {% end %}
  end

  private def validate_endpoints!(router : Router, declarations : Array(Tuple(String, String))) : Nil
    seen = {} of Tuple(String, String) => String
    router.route_handler.registered_routes.each do |(method, path)|
      Router::RouteHandler.optional_variants(path, glob: true).each do |(variant, _)|
        seen[{method, Composition.pattern(variant)}] = "registered #{method} #{path}"
      end
    end
    declarations.each do |(owner, path)|
      [{path, %w[GET HEAD POST DELETE]}, {Transport::RESOURCE_METADATA_PATH + path, %w[GET HEAD]}].each do |(endpoint_path, methods)|
        Router::RouteHandler.optional_variants(endpoint_path, glob: true).each do |(variant, _)|
          methods.each do |method|
            key = {method, Composition.pattern(variant)}
            if previous = seen[key]?
              raise ArgumentError.new("conflicting MCP endpoint #{method} #{variant}: #{previous} and #{owner}")
            end
            seen[key] = owner
          end
        end
      end
    end
  end

  protected def load_description(composition : Composition) : Description
    if File.exists?(description_path)
      description = Description.from_yaml(File.read(description_path))
      missing = endpoint_paths(composition).reject { |path| description.endpoint?(path) }
      compatible = description.composition_id == composition.signature ||
                   (description.composition_id.nil? && !composition.explicit? && Composition.mounts.empty?)
      return description if missing.empty? && compatible

      Log.warn { "#{description_path} is out of date for this composition (missing endpoints: #{missing.join(", ")}). Regenerate it using `ActionController::MCPServer.write_description`" }
      generate_description(docs: false, composition: composition)
    else
      Log.warn { "#{description_path} not found, tool descriptions will be missing. Generate it using `ActionController::MCPServer.write_description`" }
      generate_description(docs: false, composition: composition)
    end
  end
end

require "./mcp/*"

# :nodoc:
class ActionController::Composition
  getter mcp_description_cache : Atomic(MCPServer::CachedDescription?) = Atomic(MCPServer::CachedDescription?).new(nil)
end
