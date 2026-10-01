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

    def initialize(@name, @description, @verb, @path, @params, @body, @input_schema)
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

  # a controller exposed as a group of tools
  class Toolbox
    include JSON::Serializable
    include YAML::Serializable

    getter name : String
    getter controller : String
    getter description : String?
    getter tools : Array(Tool)

    def initialize(@name, @controller, @description, @tools = [] of Tool)
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
  end

  # :nodoc:
  alias RouteInfo = NamedTuple(controller: String, method: String, verb: String, route: String)

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
          {% if details[:verb] != "websocket" && !details[:mcp_hide] %}
            {
              controller: {{ details[:controller] }},
              method: {{ details[:method] }},
              verb: {{ details[:verb] }},
              route: {{ details[:route] }},
            },
          {% end %}
        {% end %}
      ] of RouteInfo

      build_description(open_api, descriptions, routes.select { |route| concrete.includes?(route[:controller]) })
    {% end %}
  end

  # :nodoc:
  def build_description(open_api, descriptions : Hash(String, OpenAPI::KlassDoc), routes : Array(RouteInfo)) : Description
    schemas = open_api[:components].schemas
    toolboxes = {} of String => Toolbox
    tool_names = Hash(String, Int32).new(0)

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

      controller = route[:controller]
      toolbox = toolboxes[controller] ||= Toolbox.new(
        tool_name(controller.underscore.gsub("::", "_")),
        controller,
        descriptions[controller]?.try(&.docs).try(&.strip).presence,
      )

      # ensure tool names are unique
      name = tool_name("#{toolbox.name}_#{route[:method]}")
      index = tool_names[name] += 1
      name = "#{name}_#{index}" if index > 1

      description = operation.description || operation.summary || "#{route[:verb].upcase} #{route[:route]}"
      toolbox.tools << build_tool(name, description, route, operation, schemas)
    end

    Description.new(toolboxes.values)
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

    Tool.new(name, description, route[:verb], route[:route], params, body, json_schema(JSON::Any.new(input_schema)))
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
