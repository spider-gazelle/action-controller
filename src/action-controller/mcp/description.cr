module ActionController::MCPServer
  # :nodoc:
  # stores JSON schemas in YAML files
  module JSONAnyConverter
    def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : JSON::Any
      JSON.parse(YAML::Any.new(ctx, node).to_json)
    end

    def self.to_yaml(value : JSON::Any, yaml : YAML::Nodes::Builder) : Nil
      value.to_yaml(yaml)
    end
  end

  # :nodoc:
  # stores arrays of JSON values, such as icons, in YAML files
  module JSONAnyArrayConverter
    def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : Array(JSON::Any)
      JSON.parse(YAML::Any.new(ctx, node).to_json).as_a
    end

    def self.to_yaml(value : Array(JSON::Any), yaml : YAML::Nodes::Builder) : Nil
      value.to_yaml(yaml)
    end
  end

  # a route argument and where it is placed in the request
  struct ToolParam
    include JSON::Serializable
    include YAML::Serializable

    getter name : String

    # path, query or header
    getter in : String

    def initialize(@name, @in)
    end
  end

  # a route exposed as a tool
  class Tool
    include JSON::Serializable
    include YAML::Serializable

    getter name : String
    getter description : String?
    getter verb : String

    # the route template, i.e. `/users/:id`
    getter path : String
    getter params : Array(ToolParam)

    # the argument that holds the request body, if any
    getter body : String?

    # JSON schema describing the tool arguments
    @[YAML::Field(converter: ActionController::MCPServer::JSONAnyConverter)]
    getter input_schema : JSON::Any

    # always available, without opening the toolbox
    getter? root : Bool = false

    # what the tool does, see `behaviours`. `nil` infers it from the HTTP verb
    getter behaviour : Array(String)? = nil

    # who can call the tool, `model` and/or `card`. `nil` is both
    getter visibility : Array(String)? = nil

    # the display name
    getter title : String? = nil

    # icons, `src` as written, see `Icons`
    @[YAML::Field(converter: ActionController::MCPServer::JSONAnyArrayConverter)]
    getter icons : Array(JSON::Any)? = nil

    # the MCP Apps card rendered for the tool, i.e. `ui://bookings/card.html`
    getter ui : String? = nil

    def initialize(@name, @description, @verb, @path, @params, @body, @input_schema, @root = false, @behaviour = nil, @ui = nil, @visibility = nil, @title = nil, @icons = nil)
    end

    # what the tool does, `@[AC::MCP(behaviour:)]` or inferred from the HTTP verb
    def behaviours : Array(String)
      @behaviour || case verb
      when "get"    then ["read_only"]
      when "put"    then ["idempotent"]
      when "delete" then ["destructive", "idempotent"]
      else               [] of String
      end
    end

    # only reads data, can be run by `call_read_only`
    def read_only? : Bool
      behaviours.includes?("read_only")
    end

    # the model can call the tool, it's not for cards only
    def model? : Bool
      @visibility.nil? || @visibility.as(Array(String)).includes?("model")
    end

    # the proxy tool that runs this tool, for clients that can't see it
    def proxy : String
      read_only? ? "call_read_only" : "call_tool"
    end

    # the tool definition as returned by `tools/list`, `proxy: true` also names the
    # proxy tool that runs it and `ui: true` includes the MCP Apps metadata.
    # `host` resolves icon paths
    def to_mcp_json(json : JSON::Builder, proxy : Bool = false, ui : Bool = false, host : String? = nil, bound : Hash(String, String)? = nil) : Nil
      json.object do
        json.field "name", name
        json.field "title", title if title
        json.field "description", description if description
        json.field "inputSchema", schema_for(bound)
        json.field "proxy", self.proxy if proxy
        Icons.to_json(json, icons, host)
        ui_meta(json) if ui
        json.field "annotations" do
          json.object do
            json.field "title", title if title
            hints(json)
          end
        end
      end
    end

    private def schema_for(bound : Hash(String, String)?) : JSON::Any
      return input_schema unless bound
      return input_schema if bound.empty?
      names = params.select { |param| param.in == "path" && bound.has_key?(param.name) }.map(&.name)
      return input_schema if names.empty?
      schema = input_schema.as_h.dup
      if properties = schema["properties"]?.try(&.as_h?)
        schema["properties"] = JSON::Any.new(properties.reject { |name, _| names.includes?(name) })
      end
      if required = schema["required"]?.try(&.as_a?)
        remaining = required.reject { |name| names.includes?(name.as_s) }
        if remaining.empty?
          schema.delete("required")
        else
          schema["required"] = JSON::Any.new(remaining)
        end
      end
      JSON::Any.new(schema)
    end

    # the card the host renders for the results and who can call the tool
    private def ui_meta(json : JSON::Builder) : Nil
      resource = self.ui.try { |uri| UI.versioned(uri) }
      visible = visibility
      return unless resource || visible

      json.field "_meta" do
        json.object do
          json.field "ui" do
            json.object do
              json.field "resourceUri", resource if resource
              # the spec calls cards apps
              json.field "visibility", visible.map { |who| who == "card" ? "app" : who } if visible
            end
          end
          # deprecated, but still read by some hosts
          json.field "ui/resourceUri", resource if resource
        end
      end
    end

    # tool annotations, hosts use them to decide what to confirm with the user
    private def hints(json : JSON::Builder) : Nil
      behaviour = behaviours
      json.field "readOnlyHint", behaviour.includes?("read_only")
      if behaviour.includes?("destructive")
        json.field "destructiveHint", true
      elsif behaviour.includes?("additive")
        json.field "destructiveHint", false
      end
      json.field "idempotentHint", true if behaviour.includes?("idempotent")
      if behaviour.includes?("open_world")
        json.field "openWorldHint", true
      elsif behaviour.includes?("closed_world")
        json.field "openWorldHint", false
      end
    end
  end

  # an argument accepted by a prompt
  struct PromptArgument
    include JSON::Serializable
    include YAML::Serializable

    getter name : String

    # path, query or header
    getter in : String
    getter description : String?
    getter? required : Bool

    def initialize(@name, @in, @description, @required)
    end
  end

  # a controller method exposed as a prompt, see `ActionController::MCP`
  class Prompt
    include JSON::Serializable
    include YAML::Serializable

    getter name : String
    getter description : String?

    # the internal route that renders the prompt
    getter path : String
    getter arguments : Array(PromptArgument)

    # always available, without opening the toolbox
    getter? root : Bool = false

    # the display name
    getter title : String? = nil

    # icons, `src` as written, see `Icons`
    @[YAML::Field(converter: ActionController::MCPServer::JSONAnyArrayConverter)]
    getter icons : Array(JSON::Any)? = nil

    def initialize(@name, @description, @path, @arguments, @root = false, @title = nil, @icons = nil)
    end

    # the prompt definition as returned by `prompts/list`, `host` resolves icon paths
    def to_mcp_json(json : JSON::Builder, host : String? = nil, bound : Hash(String, String)? = nil) : Nil
      json.object do
        json.field "name", name
        json.field "title", title if title
        json.field "description", description if description
        Icons.to_json(json, icons, host)
        json.field "arguments" do
          json.array do
            arguments.each do |argument|
              next if argument.in == "path" && bound.try(&.has_key?(argument.name))
              json.object do
                json.field "name", argument.name
                json.field "description", argument.description if argument.description
                json.field "required", argument.required?
              end
            end
          end
        end
      end
    end
  end

  # a controller exposed as a group of tools and prompts
  class Toolbox
    include JSON::Serializable
    include YAML::Serializable

    getter name : String
    getter controller : String
    getter description : String?
    getter tools : Array(Tool)
    getter prompts : Array(Prompt) = [] of Prompt

    # the controller's icons, `src` as written, see `Icons`
    @[YAML::Field(converter: ActionController::MCPServer::JSONAnyArrayConverter)]
    getter icons : Array(JSON::Any)? = nil

    def initialize(@name, @controller, @description, @tools = [] of Tool, @prompts = [] of Prompt, @icons = nil)
    end

    # the tools added when the toolbox is opened
    def toolbox_tools : Array(Tool)
      tools.reject(&.root?)
    end

    # the prompts added when the toolbox is opened
    def toolbox_prompts : Array(Prompt)
      prompts.reject(&.root?)
    end

    # true if there is anything to add when the toolbox is opened
    def openable? : Bool
      tools.any? { |tool| !tool.root? } || prompts.any? { |prompt| !prompt.root? }
    end
  end

  # the toolboxes available to MCP clients, typically saved as `mcp.yml`
  class Description
    include JSON::Serializable
    include YAML::Serializable

    getter toolboxes : Array(Toolbox)

    # controllers served as their own MCP server, see `ActionController::MCP`
    getter endpoints : Array(Endpoint) = [] of Endpoint

    # Detects descriptions generated for a different application composition.
    property composition_id : String? = nil

    def initialize(@toolboxes = [] of Toolbox, @endpoints = [] of Endpoint)
    end

    # the endpoint served at the path template, i.e. `/accounts/:account_id/mcp`
    def endpoint?(path : String) : Endpoint?
      endpoints.find(&.path.==(path))
    end

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @toolbox_lookup : Hash(String, Toolbox)? = nil

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @tool_lookup : Hash(String, Tuple(Toolbox, Tool))? = nil

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @prompt_lookup : Hash(String, Tuple(Toolbox, Prompt))? = nil

    def toolbox?(name : String) : Toolbox?
      lookup = @toolbox_lookup ||= toolboxes.to_h { |box| {box.name, box} }
      lookup[name]?
    end

    # returns the tool and the toolbox it belongs to
    def tool?(name : String) : Tuple(Toolbox, Tool)?
      lookup = @tool_lookup ||= begin
        tools = {} of String => Tuple(Toolbox, Tool)
        toolboxes.each { |box| box.tools.each { |tool| tools[tool.name] = {box, tool} } }
        tools
      end
      lookup[name]?
    end

    # returns the prompt and the toolbox it belongs to
    def prompt?(name : String) : Tuple(Toolbox, Prompt)?
      lookup = @prompt_lookup ||= begin
        prompts = {} of String => Tuple(Toolbox, Prompt)
        toolboxes.each { |box| box.prompts.each { |prompt| prompts[prompt.name] = {box, prompt} } }
        prompts
      end
      lookup[name]?
    end

    def prompts? : Bool
      toolboxes.any? { |box| !box.prompts.empty? }
    end

    # true if any tool renders an MCP Apps card
    def ui? : Bool
      toolboxes.any? { |box| box.tools.any? { |tool| tool.ui || tool.visibility } }
    end

    # the tools available without opening a toolbox
    def root_tools : Array(Tool)
      toolboxes.flat_map { |box| box.tools.select(&.root?) }
    end

    # the prompts available without opening a toolbox
    def root_prompts : Array(Prompt)
      toolboxes.flat_map { |box| box.prompts.select(&.root?) }
    end
  end

  # a controller served as its own MCP server, `@[AC::MCP(endpoint: true)]`.
  # Every tool and prompt is listed, there are no toolboxes to open
  class Endpoint
    include JSON::Serializable
    include YAML::Serializable

    # the path template the endpoint is served at, i.e. `/accounts/:account_id/mcp`
    getter path : String

    # the path params bound from the endpoint URL, removed from the tool arguments
    getter bound : Array(String)

    # the endpoint's tools and prompts, all of them root items
    getter toolbox : Toolbox

    # the internal route of the controller's `instructions` method, which builds the
    # instructions for each session, i.e. `/accounts/:account_id/__mcp_instructions__`
    getter instructions_path : String? = nil

    def initialize(@path, @bound, @toolbox, @instructions_path = nil)
    end

    # the toolbox name, used as the server name
    def name : String
      toolbox.name
    end

    # the controller doc comment, used as the server instructions
    def instructions : String?
      toolbox.description
    end

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @description : Description? = nil

    # the endpoint as a description with a single toolbox of root items
    def description : Description
      @description ||= Description.new([toolbox])
    end

    # the path params in a path template
    def self.bound_params(path : String) : Array(String)
      path.split('/').select { |segment| segment.starts_with?(':') || segment.starts_with?("?:") || segment.starts_with?("*:") }.map { |segment| segment.split(':', 2)[1] }
    end
  end

  # :nodoc:
  # `global`: listed by the global server, `endpoint`: the endpoint path it's served on
  alias RouteInfo = NamedTuple(controller: String, method: String, verb: String, route: String, root: Bool, behaviour: Array(String)?, global: Bool, endpoint: String?, ui: String?, visibility: Array(String)?, title: String?, icons: Array(String)?, toolbox_icons: Array(String)?)

  # :nodoc:
  alias PromptInfo = NamedTuple(controller: String, method: String, route: String, root: Bool, arguments: Array(PromptArgument), declared_arguments: Array(String), global: Bool, endpoint: String?, title: String?, icons: Array(String)?, toolbox_icons: Array(String)?)

  # generates the MCP description from the compiled routes.
  #
  # `docs: true` extracts the source code comments using `crystal docs`,
  # which requires access to the source code
  def generate_description(docs : Bool = true, composition : Composition = Composition.default) : Description
    generate_description(docs ? OpenAPI.extract_route_descriptions : {} of String => OpenAPI::KlassDoc, composition)
  end

  # :nodoc:
  # generates the MCP description using the provided class and method descriptions
  def generate_description(descriptions : Hash(String, OpenAPI::KlassDoc), composition : Composition = Composition.default) : Description
    open_api = OpenAPI.generate_open_api_docs(descriptions, server_name, server_version, composition: composition)

    # expanded when the method is used, once all the routes are known
    {% begin %}
      routes = [
        {% for _route_key, details in ::ActionController::Route::Builder::OPENAPI_ROUTES %}
          {% endpoint = details[:mcp_endpoint_hide] ? nil : details[:mcp_endpoint] %}
          {% if Base::CONCRETE_CONTROLLERS[details[:controller].id] && details[:verb] != "websocket" && !details[:mcp_prompt] && (!details[:mcp_hide] || endpoint) %}
            {
              controller: {{ details[:controller] }},
              method: {{ details[:method] }},
              verb: {{ details[:verb] }},
              route: {{ details[:route] }},
              root: {{ details[:mcp_root] == true }},
              behaviour: {{ details[:mcp_behaviour] }}.as(Array(String)?),
              global: {{ !details[:mcp_hide] }},
              endpoint: {{ endpoint }}.as(String?),
              ui: {{ details[:mcp_ui] }}.as(String?),
              visibility: {{ details[:mcp_visibility] }}.as(Array(String)?),
              title: {{ details[:mcp_title] }}.as(String?),
              icons: {% if details[:mcp_icons] && !details[:mcp_icons].empty? %}[{% for icon in details[:mcp_icons] %}{{ icon }}.to_json, {% end %}].as(Array(String)?){% else %}nil.as(Array(String)?){% end %},
              toolbox_icons: {% if details[:mcp_toolbox_icons] && !details[:mcp_toolbox_icons].empty? %}[{% for icon in details[:mcp_toolbox_icons] %}{{ icon }}.to_json, {% end %}].as(Array(String)?){% else %}nil.as(Array(String)?){% end %},
            },
          {% end %}
        {% end %}
      ] of RouteInfo

      prompts = [
        {% for _route_key, details in ::ActionController::Route::Builder::OPENAPI_ROUTES %}
          {% endpoint = details[:mcp_endpoint_hide] ? nil : details[:mcp_endpoint] %}
          {% if Base::CONCRETE_CONTROLLERS[details[:controller].id] && details[:mcp_prompt] && !details[:mcp_instructions] && (!details[:mcp_hide] || endpoint) %}
            {
              controller: {{ details[:controller] }},
              method: {{ details[:method] }},
              route: {{ details[:route] }},
              root: {{ details[:mcp_root] == true }},
              arguments: [
                {% for param_name, param in details[:params] %}
                  PromptArgument.new(
                    {{ param[:header] || param_name }},
                    {{ param[:in].id.stringify }},
                    {{ param[:docs] }}.as(String?),
                    {{ param[:required] == true }},
                  ),
                {% end %}
              ] of PromptArgument,
              declared_arguments: [
                {% for param_name, param in details[:params] %}
                  {% if param[:schema].stringify != "Nil" %}
                    {{ param[:header] || param_name }},
                  {% end %}
                {% end %}
              ] of String,
              global: {{ !details[:mcp_hide] }},
              endpoint: {{ endpoint }}.as(String?),
              title: {{ details[:mcp_title] }}.as(String?),
              icons: {% if details[:mcp_icons] && !details[:mcp_icons].empty? %}[{% for icon in details[:mcp_icons] %}{{ icon }}.to_json, {% end %}].as(Array(String)?){% else %}nil.as(Array(String)?){% end %},
              toolbox_icons: {% if details[:mcp_toolbox_icons] && !details[:mcp_toolbox_icons].empty? %}[{% for icon in details[:mcp_toolbox_icons] %}{{ icon }}.to_json, {% end %}].as(Array(String)?){% else %}nil.as(Array(String)?){% end %},
            },
          {% end %}
        {% end %}
      ] of PromptInfo

      # controller => the internal route of its `instructions` method
      instructions = {
        {% for _route_key, details in ::ActionController::Route::Builder::OPENAPI_ROUTES %}
          {% if details[:mcp_instructions] %}
            {{ details[:controller] }} => {{ details[:route] }},
          {% end %}
        {% end %}
      } of String => String

      placed_description(open_api, descriptions, routes, prompts, instructions, composition)
    {% end %}
  end

  # :nodoc:
  alias PlacementNames = Hash(Tuple(String, String), Tuple(String, String?))

  # :nodoc:
  def placed_description(open_api, descriptions, routes, prompts, instructions, composition : Composition) : Description
    placed_routes = [] of RouteInfo
    placed_prompts = [] of PromptInfo
    placed_instructions = {} of String => String
    identities = PlacementNames.new
    controllers = composition.placements.map(&.controller.name)
    namespace = common_namespace(controllers)
    counts = controllers.tally
    names = Hash(String, Int32).new(0)
    composition.placements.each do |placement|
      controller = placement.controller.name
      identity = "#{controller}\0#{placement.base}"
      label = toolbox_name(controller, namespace)
      label += "_#{tool_name(placement.base)}" if counts[controller] > 1
      label = unique_name(names, label)
      routes.select(&.[:controller].==(controller)).each do |route|
        path = placement.path(route[:route])
        endpoint = route[:endpoint].try { |value| placement.path(value) }
        placed_routes << route.merge(route: path, endpoint: endpoint)
        identities[{controller, path}] = {identity, label.as(String?)}
      end
      prompts.select(&.[:controller].==(controller)).each do |prompt|
        path = placement.path(prompt[:route])
        path_names = path.split('/').select { |segment| segment.starts_with?(':') || segment.starts_with?("?:") || segment.starts_with?("*:") }.map { |segment| segment.split(':', 2)[1] }
        arguments = prompt[:arguments].compact_map do |argument|
          if argument.in == "path" && !path_names.includes?(argument.name)
            next unless prompt[:declared_arguments].includes?(argument.name)
            PromptArgument.new(argument.name, "query", argument.description, argument.required?)
          elsif (argument.in == "query" || argument.in == "path") && path_names.includes?(argument.name)
            PromptArgument.new(argument.name, "path", argument.description, argument.required? || path.split('/').includes?(":#{argument.name}"))
          else
            argument
          end
        end
        path.split('/').each do |segment|
          next unless segment.starts_with?(':') || segment.starts_with?("?:") || segment.starts_with?("*:")
          name = segment.split(':', 2)[1]
          next if arguments.any? { |argument| argument.in == "path" && argument.name == name }
          arguments << PromptArgument.new(name, "path", nil, segment.starts_with?(':'))
        end
        endpoint = prompt[:endpoint].try { |value| placement.path(value) }
        placed_prompts << prompt.merge(route: path, endpoint: endpoint, arguments: arguments)
        identities[{controller, path}] = {identity, label.as(String?)}
      end
      if instruction = instructions[controller]?
        endpoint_paths_for(controller).each do |endpoint|
          placed_instructions["#{controller}\0#{placement.path(endpoint)}"] = placement.path(instruction)
        end
      end
    end
    description = build_description(open_api, descriptions, placed_routes, placed_prompts, placed_instructions, identities)
    description.composition_id = composition.signature
    description
  end

  private def endpoint_paths_for(controller : String) : Array(String)
    {% begin %}
      paths = [
        {% for _key, details in Route::Builder::OPENAPI_ROUTES %}
          {% if details[:mcp_endpoint] %}
            { {{ details[:controller] }}, {{ details[:mcp_endpoint] }} },
          {% end %}
        {% end %}
      ] of Tuple(String, String)
      paths.select(&.[0].==(controller)).map(&.[1]).uniq
    {% end %}
  end

  # :nodoc:
  def build_description(open_api, descriptions : Hash(String, OpenAPI::KlassDoc), routes : Array(RouteInfo), prompts : Array(PromptInfo) = [] of PromptInfo, instructions : Hash(String, String) = {} of String => String, identities : PlacementNames = PlacementNames.new) : Description
    namespace = common_namespace(routes.map(&.[:controller]) + prompts.map(&.[:controller]))

    toolboxes = build_toolboxes(open_api, descriptions, routes.select(&.[:global]), prompts.select(&.[:global]), namespace, identities: identities) do |toolbox, method|
      "#{toolbox.name}_#{method}"
    end

    # each endpoint is a single toolbox of root items, named by method
    endpoint_routes = routes.select(&.[:endpoint])
    endpoint_prompts = prompts.select(&.[:endpoint])
    paths = (endpoint_routes.map(&.[:endpoint]) + endpoint_prompts.map(&.[:endpoint])).compact.uniq!
    endpoints = paths.compact_map do |path|
      bound = Endpoint.bound_params(path)
      always_bound = path.split('/').compact_map(&.lchop?(':'))
      boxes = build_toolboxes(open_api, descriptions, endpoint_routes.select(&.[:endpoint].==(path)), endpoint_prompts.select(&.[:endpoint].==(path)), namespace, root: true, bound: always_bound, identities: identities) do |_toolbox, method|
        method
      end
      boxes.first?.try { |box| Endpoint.new(path, bound, box, instructions["#{box.controller}\0#{path}"]? || instructions[box.controller]?) }
    end

    Description.new(toolboxes, endpoints)
  end

  # one toolbox per controller. `root` makes every item a root item, and `bound`
  # path params are left out of the tool arguments
  private def build_toolboxes(open_api, descriptions : Hash(String, OpenAPI::KlassDoc), routes : Array(RouteInfo), prompts : Array(PromptInfo), namespace : Array(String), root : Bool = false, bound : Array(String) = [] of String, identities : PlacementNames = PlacementNames.new, & : Toolbox, String -> String) : Array(Toolbox)
    schemas = open_api[:components].schemas
    toolboxes = {} of String => Toolbox
    tool_names = Hash(String, Int32).new(0)
    prompt_names = Hash(String, Int32).new(0)

    # A method with several route annotations is a single tool. Routes arrive in
    # verb order (GET, POST, PUT, PATCH, DELETE), source order within a verb, so
    # the tool uses the method's first GET route, otherwise its first route.
    methods = Set(Tuple(String, String)).new

    routes.each do |route|
      identity, label = identities[{route[:controller], route[:route]}]? || {route[:controller], nil.as(String?)}
      next if methods.includes?({identity, route[:method]})
      path = open_api[:paths][OpenAPI.openapi_path(route[:route])]?
      operation = case route[:verb]
                  when "get"    then path.try &.get
                  when "post"   then path.try &.post
                  when "put"    then path.try &.put
                  when "patch"  then path.try &.patch
                  when "delete" then path.try &.delete
                  end
      next unless operation

      toolbox = toolbox_for(toolboxes, route[:controller], namespace, descriptions, route[:toolbox_icons], identity, label)
      name = unique_name(tool_names, yield(toolbox, route[:method]))
      description = operation.description || operation.summary || "#{route[:verb].upcase} #{route[:route]}"
      route = route.merge(root: true) if root
      toolbox.tools << build_tool(name, description, route, operation, schemas, bound)
      methods << {identity, route[:method]}
    end

    prompts.each do |prompt|
      identity, label = identities[{prompt[:controller], prompt[:route]}]? || {prompt[:controller], nil.as(String?)}
      toolbox = toolbox_for(toolboxes, prompt[:controller], namespace, descriptions, prompt[:toolbox_icons], identity, label)
      name = unique_name(prompt_names, yield(toolbox, prompt[:method]))
      description = method_docs(descriptions, prompt[:controller], prompt[:method]).try(&.strip)
      arguments = prompt[:arguments].reject { |argument| argument.in == "path" && bound.includes?(argument.name) }
      toolbox.prompts << Prompt.new(name, description, prompt[:route], arguments, root || prompt[:root], prompt[:title], parse_icons(prompt[:icons]))
    end

    toolboxes.values
  end

  private def toolbox_for(toolboxes : Hash(String, Toolbox), controller : String, namespace : Array(String), descriptions : Hash(String, OpenAPI::KlassDoc), icons : Array(String)?, identity : String = controller, label : String? = nil) : Toolbox
    toolboxes[identity] ||= Toolbox.new(
      label || toolbox_name(controller, namespace),
      controller,
      descriptions[controller]?.try(&.docs).try(&.strip).presence,
      icons: parse_icons(icons),
    )
  end

  private def parse_icons(icons : Array(String)?) : Array(JSON::Any)?
    icons.try &.map { |icon| JSON.parse(icon) }
  end

  # :nodoc:
  # The module namespace shared by every controller, i.e. `["PlaceOS", "Api"]`
  # for `PlaceOS::Api::Zones` and `PlaceOS::Api::Groups::Users`. It's redundant
  # in toolbox and tool names, so it's omitted. Never includes a controller's
  # own name, so a name is never empty, and as every name loses the same
  # prefix they remain unique.
  def common_namespace(controllers : Enumerable(String)) : Array(String)
    namespaces = controllers.map(&.split("::")[0...-1])
    return [] of String if namespaces.empty?

    namespaces.reduce do |common, namespace|
      shared = 0
      while shared < common.size && shared < namespace.size && common[shared] == namespace[shared]
        shared += 1
      end
      common[0, shared]
    end
  end

  # :nodoc:
  # the snake case controller name without the common namespace, `groups_users`
  def toolbox_name(controller : String, namespace : Array(String)) : String
    tool_name(controller.split("::")[namespace.size..].join("::").underscore.gsub("::", "_"))
  end

  # ensures names are unique
  private def unique_name(names : Hash(String, Int32), name : String) : String
    name = tool_name(name)
    index = names[name] += 1
    index > 1 ? "#{name}_#{index}" : name
  end

  # the method comment, checking ancestor classes if required
  private def method_docs(descriptions : Hash(String, OpenAPI::KlassDoc), controller : String, method : String) : String?
    return unless controller_docs = descriptions[controller]?
    controller_docs.methods[method]? || controller_docs.ancestors.each do |ancestor|
      if docs = descriptions[ancestor]?.try(&.methods[method]?)
        return docs
      end
    end
  end

  # :nodoc:
  def build_tool(name : String, description : String, route : RouteInfo, operation : OpenAPI::Operation, schemas : Hash(String, JSON::Any), bound : Array(String) = [] of String) : Tool
    properties = {} of String => JSON::Any
    required = [] of String
    params = [] of ToolParam

    # optional (`?:`) and glob (`*:`) path segments can be left out
    optional = route[:route].split('/').select { |part| part.starts_with?("?:") || part.starts_with?("*:") }.map(&.split(':', 2)[1])

    operation.parameters.try &.each do |param|
      param_name = param.name.as(String)
      in_path = param.in == "path"
      params << ToolParam.new(param_name, param.in.as(String))
      # bound from the endpoint URL rather than provided by the model
      next if in_path && bound.includes?(param_name)

      schema = param.schema.try(&.as_h?).try(&.dup) || {} of String => JSON::Any
      schema["description"] = JSON::Any.new(param.description.as(String)) if param.description
      if example = param.example
        schema["examples"] = JSON::Any.new([example])
      end
      properties[param_name] = JSON::Any.new(schema)
      required << param_name if (param.required && !optional.includes?(param_name)) || param.query_fallback.try(&.required)
    end

    body = nil
    if request_body = operation.request_body
      content = request_body.content
      if content && (media = content["application/json"]? || content.values.first?)
        body = properties.has_key?("body") ? "request_body" : "body"
        properties[body] = media.schema
        required << body if request_body.required
      end
    end

    input_schema = {
      "type"       => JSON::Any.new("object"),
      "properties" => JSON::Any.new(properties),
    }
    input_schema["required"] = JSON::Any.new(required.map { |key| JSON::Any.new(key) }) unless required.empty?

    # include the referenced schemas so the tool schema is self contained
    definitions = {} of String => JSON::Any
    collect_definitions(JSON::Any.new(properties), schemas, definitions)
    input_schema["$defs"] = JSON::Any.new(definitions) unless definitions.empty?

    Tool.new(name, description, route[:verb], route[:route], params, body, json_schema(JSON::Any.new(input_schema)), route[:root], route[:behaviour], route[:ui], route[:visibility], route[:title], parse_icons(route[:icons]))
  end

  # :nodoc:
  # tool names are limited to 64 alphanumeric, underscore or dash characters
  def tool_name(name : String) : String
    name.gsub(/[^a-zA-Z0-9_\-]+/, '_').strip('_')[0, 64]
  end

  private SCHEMA_REF = "#/components/schemas/"

  # finds the schemas referenced and adds them to definitions
  private def collect_definitions(schema : JSON::Any, schemas : Hash(String, JSON::Any), definitions : Hash(String, JSON::Any)) : Nil
    if hash = schema.as_h?
      if (ref = hash["$ref"]?.try(&.as_s?)) && ref.starts_with?(SCHEMA_REF)
        key = ref[SCHEMA_REF.size..]
        if !definitions.has_key?(key) && (definition = schemas[key]?)
          definitions[key] = definition
          collect_definitions(definition, schemas, definitions)
        end
      end
      hash.each_value { |value| collect_definitions(value, schemas, definitions) }
    elsif array = schema.as_a?
      array.each { |value| collect_definitions(value, schemas, definitions) }
    end
  end

  # converts the OpenAPI 3.0 schema dialect into standard JSON schema
  private def json_schema(schema : JSON::Any) : JSON::Any
    if hash = schema.as_h?
      converted = {} of String => JSON::Any
      hash.each do |key, value|
        case key
        when "nullable"
          next
        when "example"
          converted["examples"] = JSON::Any.new([value])
        when "$ref"
          ref = value.as_s? || ""
          converted[key] = ref.starts_with?(SCHEMA_REF) ? JSON::Any.new("#/$defs/#{ref[SCHEMA_REF.size..]}") : value
        when "properties", "patternProperties", "$defs"
          # keys are names, not keywords
          converted[key] = value.as_h?.try { |named| JSON::Any.new(named.transform_values { |sub_schema| json_schema(sub_schema) }) } || value
        else
          converted[key] = json_schema(value)
        end
      end

      if hash["nullable"]?.try(&.as_bool?)
        if type = converted["type"]?.try(&.as_s?)
          converted["type"] = JSON::Any.new([JSON::Any.new(type), JSON::Any.new("null")])
        else
          return JSON::Any.new({"anyOf" => JSON::Any.new([JSON::Any.new(converted), JSON::Any.new({"type" => JSON::Any.new("null")})])})
        end
      end

      JSON::Any.new(converted)
    elsif array = schema.as_a?
      JSON::Any.new(array.map { |value| json_schema(value) })
    else
      schema
    end
  end
end
