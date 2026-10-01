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
  class_property forward_headers : Array(String) = ["Authorization", "Cookie"]

  # browser origins permitted to connect, in addition to same origin requests.
  # `"*"` permits any origin
  class_property allowed_origins : Array(String) = [] of String

  # sessions inactive for this period are discarded
  class_property session_timeout : Time::Span = 30.minutes

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
  # tool calls are dispatched via the router, typically `ActionController::Server`
  def mount(router : Router, path : String = "/mcp") : Transport
    transport = Transport.new(router.route_handler)
    router.post(path) { |context, _head| transport.post(context) }
    router.get(path) { |context, head| transport.get(context, head) }
    router.delete(path) { |context, _head| transport.delete(context) }
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
