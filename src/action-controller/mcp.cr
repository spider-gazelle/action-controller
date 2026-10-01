require "json"
require "yaml"
require "./open_api"
require "./router"

# Exposes the application's annotated routes as an [MCP](https://modelcontextprotocol.io) server
# using the Streamable HTTP transport.
#
# Controllers are presented as toolboxes and their routes as tools. To keep the
# model's context lean only three tools are listed by default:
#
# * `list_toolboxes` lists the controllers and their descriptions
# * `open_toolbox(name)` adds the controller's routes to the session's tool set
# * `close_toolbox(name)` removes them again
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

  # location of the MCP description file, generated using `write_description`
  class_property description_path : String = "mcp.yml"

  # reported to clients during initialization
  class_property server_name : String = "action-controller"

  # :ditto:
  class_property server_version : String = "1.0.0"

  # usage instructions provided to the model
  class_property instructions : String? = DEFAULT_INSTRUCTIONS

  # request headers copied from the MCP request to the route being invoked,
  # typically used for authentication
  class_property forward_headers : Array(String) = ["Authorization", "Cookie", "X-API-Key"]

  # browser origins permitted to connect, in addition to same origin requests.
  # `"*"` permits any origin
  class_property allowed_origins : Array(String) = [] of String

  # sessions inactive for this period are discarded
  class_property session_timeout : Time::Span = 30.minutes

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
  def mount(router : Router, path : String = "/mcp") : Transport
    transport = Transport.new(router.route_handler, path)
    router.post(path) { |context, _head| transport.post(context) }
    router.get(path) { |context, head| transport.get(context, head) }
    router.delete(path) { |context, _head| transport.delete(context) }
    router.get(Transport::RESOURCE_METADATA_PATH + path) { |context, _head| transport.resource_metadata(context) }
    transport
  end

  protected def load_description : Description
    if File.exists?(description_path)
      Description.from_yaml(File.read(description_path))
    else
      Log.warn { "#{description_path} not found, tool descriptions will be missing. Generate it using `ActionController::MCPServer.write_description`" }
      generate_description(docs: false)
    end
  end
end

require "./mcp/*"
