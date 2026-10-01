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

    def initialize(@name, @description, @verb, @path, @params, @body, @input_schema, @root = false)
    end

    # the tool definition as returned by `tools/list`
    def to_mcp_json(json : JSON::Builder) : Nil
      json.object do
        json.field "name", name
        json.field "description", description if description
        json.field "inputSchema", input_schema
        json.field "annotations" do
          json.object do
            case verb
            when "get"
              json.field "readOnlyHint", true
            when "delete"
              json.field "readOnlyHint", false
              json.field "destructiveHint", true
              json.field "idempotentHint", true
            when "put"
              json.field "readOnlyHint", false
              json.field "idempotentHint", true
            else
              json.field "readOnlyHint", false
            end
          end
        end
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

    def initialize(@name, @description, @path, @arguments, @root = false)
    end

    # the prompt definition as returned by `prompts/list`
    def to_mcp_json(json : JSON::Builder) : Nil
      json.object do
        json.field "name", name
        json.field "description", description if description
        json.field "arguments" do
          json.array do
            arguments.each do |argument|
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

    def initialize(@name, @controller, @description, @tools = [] of Tool, @prompts = [] of Prompt)
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

    def initialize(@toolboxes = [] of Toolbox)
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

    # the tools available without opening a toolbox
    def root_tools : Array(Tool)
      toolboxes.flat_map { |box| box.tools.select(&.root?) }
    end

    # the prompts available without opening a toolbox
    def root_prompts : Array(Prompt)
      toolboxes.flat_map { |box| box.prompts.select(&.root?) }
    end
  end

  # :nodoc:
  alias RouteInfo = NamedTuple(controller: String, method: String, verb: String, route: String, root: Bool)

  # :nodoc:
  alias PromptInfo = NamedTuple(controller: String, method: String, route: String, root: Bool, arguments: Array(PromptArgument))

  # generates the MCP description from the compiled routes.
  #
  # `docs: true` extracts the source code comments using `crystal docs`,
  # which requires access to the source code
  def generate_description(docs : Bool = true) : Description
    generate_description(docs ? OpenAPI.extract_route_descriptions : {} of String => OpenAPI::KlassDoc)
  end

  # :nodoc:
  # generates the MCP description using the provided class and method descriptions
  def generate_description(descriptions : Hash(String, OpenAPI::KlassDoc)) : Description
    open_api = OpenAPI.generate_open_api_docs(descriptions, server_name, server_version)

    # expanded when the method is used, once all the routes are known
    {% begin %}
      concrete = [
        {% for klass in ::ActionController::Base::CONCRETE_CONTROLLERS.keys %}
          {{klass.stringify}},
        {% end %}
      ] of String

      routes = [
        {% for _route_key, details in ::ActionController::Route::Builder::OPENAPI_ROUTES %}
          {% if details[:verb] != "websocket" && !details[:mcp_hide] && !details[:mcp_prompt] %}
            {
              controller: {{ details[:controller] }},
              method: {{ details[:method] }},
              verb: {{ details[:verb] }},
              route: {{ details[:route] }},
              root: {{ details[:mcp_root] == true }},
            },
          {% end %}
        {% end %}
      ] of RouteInfo

      prompts = [
        {% for _route_key, details in ::ActionController::Route::Builder::OPENAPI_ROUTES %}
          {% if details[:mcp_prompt] && !details[:mcp_hide] %}
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
            },
          {% end %}
        {% end %}
      ] of PromptInfo

      build_description(
        open_api,
        descriptions,
        routes.select { |route| concrete.includes?(route[:controller]) },
        prompts.select { |prompt| concrete.includes?(prompt[:controller]) },
      )
    {% end %}
  end

  # :nodoc:
  def build_description(open_api, descriptions : Hash(String, OpenAPI::KlassDoc), routes : Array(RouteInfo), prompts : Array(PromptInfo) = [] of PromptInfo) : Description
    schemas = open_api[:components].schemas
    toolboxes = {} of String => Toolbox
    tool_names = Hash(String, Int32).new(0)
    prompt_names = Hash(String, Int32).new(0)

    routes.each do |route|
      path = open_api[:paths][OpenAPI.openapi_path(route[:route])]?
      operation = case route[:verb]
                  when "get"    then path.try &.get
                  when "post"   then path.try &.post
                  when "put"    then path.try &.put
                  when "patch"  then path.try &.patch
                  when "delete" then path.try &.delete
                  end
      next unless operation

      toolbox = toolbox_for(toolboxes, route[:controller], descriptions)
      name = unique_name(tool_names, "#{toolbox.name}_#{route[:method]}")
      description = operation.description || operation.summary || "#{route[:verb].upcase} #{route[:route]}"
      toolbox.tools << build_tool(name, description, route, operation, schemas)
    end

    prompts.each do |prompt|
      toolbox = toolbox_for(toolboxes, prompt[:controller], descriptions)
      name = unique_name(prompt_names, "#{toolbox.name}_#{prompt[:method]}")
      description = method_docs(descriptions, prompt[:controller], prompt[:method]).try(&.strip)
      toolbox.prompts << Prompt.new(name, description, prompt[:route], prompt[:arguments], prompt[:root])
    end

    Description.new(toolboxes.values)
  end

  private def toolbox_for(toolboxes : Hash(String, Toolbox), controller : String, descriptions : Hash(String, OpenAPI::KlassDoc)) : Toolbox
    toolboxes[controller] ||= Toolbox.new(
      tool_name(controller.underscore.gsub("::", "_")),
      controller,
      descriptions[controller]?.try(&.docs).try(&.strip).presence,
    )
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
  def build_tool(name : String, description : String, route : RouteInfo, operation : OpenAPI::Operation, schemas : Hash(String, JSON::Any)) : Tool
    properties = {} of String => JSON::Any
    required = [] of String
    params = [] of ToolParam

    operation.parameters.try &.each do |param|
      param_name = param.name.as(String)
      schema = param.schema.try(&.as_h?).try(&.dup) || {} of String => JSON::Any
      schema["description"] = JSON::Any.new(param.description.as(String)) if param.description
      schema["examples"] = JSON::Any.new([JSON::Any.new(param.example.as(String))]) if param.example
      properties[param_name] = JSON::Any.new(schema)
      required << param_name if param.required
      params << ToolParam.new(param_name, param.in.as(String))
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

    Tool.new(name, description, route[:verb], route[:route], params, body, json_schema(JSON::Any.new(input_schema)), route[:root])
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
