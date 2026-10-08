require "uri"
require "yaml"
require "./open_api/*"

module ActionController::OpenAPI
  extend self

  # :nodoc:
  alias Params = NamedTuple(
    name: String,
    in: Symbol,
    required: Bool?,
    schema: String,
    docs: String?,
    example: String?,
  )

  # :nodoc:
  alias Filter = NamedTuple(
    controller: String,
    method: String,
    wrapper_method: String,
    filter_key: String,
    request_body: String,
    params: Array(Params),
  )

  # :nodoc:
  alias ExceptionHandler = NamedTuple(
    method: String,
    controller: String,
    exception_name: String,
    exception_key: String,
  )

  # :nodoc:
  alias RouteDetails = NamedTuple(
    route_lookup: String,
    verb: String,
    route: String,
    params: Array(Params),
    original_params: Array(Params),
    method: String,
    filters: Array(String),
    error_handlers: Array(String),
    controller: String,
    request_body: String,
    route_responses: Hash(Tuple(Bool, String), Int32),
  )

  # :nodoc:
  SAVE_DESCRIPTIONS_OF = {"ActionController::Base", "JSON::Serializable", "YAML::Serializable"}

  # :nodoc:
  def extract_all_types(type_collection, current_list)
    type_collection.concat current_list
    current_list.each do |current_type|
      if next_list = current_type["types"]?.try &.as_a
        extract_all_types(type_collection, next_list)
      end
    end
  end

  # :nodoc:
  def extract_route_descriptions
    output = IO::Memory.new

    status = Process.run(
      "crystal",
      args: {"docs", "--format=json"},
      output: output
    )

    raise "failed to obtain route descriptions via 'crystal docs'" unless status.success?

    # flatten the program type tree
    program_types = [] of JSON::Any
    if extracted_types = JSON.parse(output.to_s)["program"]["types"]?.try &.as_a
      extract_all_types(program_types, extracted_types)
    end

    docs = {} of String => KlassDoc

    program_types.each do |type|
      klass_docs = KlassDoc.new(type["full_name"].as_s, type["doc"]?.try &.as_s)
      docs[klass_docs.name] = klass_docs

      # check if we want the method docs of this class
      save_methods = false
      modules = [] of String
      ancestors = [] of String
      type["ancestors"]?.try &.as_a.each do |klass|
        full_name = klass["full_name"].as_s
        if SAVE_DESCRIPTIONS_OF.includes?(full_name)
          save_methods = true
          break
        elsif klass["kind"].as_s == "module"
          modules << full_name
        else
          ancestors << full_name
        end
      end
      next unless save_methods

      # We save the ancestors so we can find the first filter or exception match
      klass_docs.ancestors.concat ancestors

      # grab method docs from modules (local class methods will take override as required)
      modules.each do |module_name|
        program_types.each do |mod_type|
          next unless mod_type["full_name"].as_s == module_name

          # save the instance method docs
          mod_type["instance_methods"]?.try &.as_a.each do |method|
            if doc = method["doc"]?
              klass_docs.methods[method["name"].as_s] = doc.as_s
            end
          end
        end
      end

      # save the instance method docs
      type["instance_methods"]?.try &.as_a.each do |method|
        if doc = method["doc"]?
          klass_docs.methods[method["name"].as_s] = doc.as_s
        end
      end
    end

    # ClassName => details
    docs
  end

  # :nodoc:
  def find_matching(
    klass_descriptions : Hash(String, KlassDoc),
    controller : String,
    all_filters,
    all_exceptions,
    route_filters : Array(String),
    route_errors : Array(String),
  ) : Tuple(KlassDoc?, Array(String), Array(String))
    if description = klass_descriptions[controller]?
      matched_filters = route_filters.compact_map do |filter_name|
        matched = all_filters.select { |_key, filter| filter[:wrapper_method] == filter_name }.values
        found = matched.first?.try &.[](:filter_key)
        matched.each do |filter|
          if description.implements?(filter)
            found = filter[:filter_key]
            break
          end
        end
        found
      end

      matched_errors = route_errors.compact_map do |error_name|
        matched = all_exceptions.select { |_key, error| error[:exception_name] == error_name }.values
        found = matched.first?.try &.[](:exception_key)
        matched.each do |error|
          if description.implements?(error)
            found = error[:exception_key]
            break
          end
        end
        found
      end
    else
      # we pick the first match (best guess)
      matched_filters = route_filters.compact_map do |filter_name|
        matched = all_filters.select { |_key, filter| filter[:wrapper_method] == filter_name }.values
        matched.first?.try &.[](:filter_key)
      end

      matched_errors = route_errors.compact_map do |error_name|
        matched = all_exceptions.select { |_key, error| error[:exception_name] == error_name }.values
        matched.first?.try &.[](:exception_key)
      end
    end
    {description, matched_filters, matched_errors}
  end

  # the OpenAPI versions that can be generated, the first is the default
  OPENAPI_VERSIONS = {"3.1.0", "3.0.3"}

  # returns a NamedTuple that represents the OpenAPI docs for the current application.
  #
  # `openapi` is the version of the document, `"3.1.0"` (the default) or `"3.0.3"`.
  # the info hash splat accepts any of the keys from the [info object](https://swagger.io/specification/#info-object)
  def generate_open_api_docs(title : String, version : String, openapi : String = OPENAPI_VERSIONS[0], composition : Composition = Composition.default, **info)
    generate_open_api_docs(extract_route_descriptions, title, version, openapi, composition, **info)
  end

  # :nodoc:
  # the schema of a type, in the JSON Schema dialect of the OpenAPI version being generated
  macro introspect_schema(type)
    (openapi_3_0 ? ::JSON::Schema.introspect({{type}}, openapi: true, refs: definitions) : ::JSON::Schema.introspect({{type}}, refs: definitions))
  end

  # :nodoc:
  # generates the OpenAPI docs using the provided class and method descriptions
  def generate_open_api_docs(descriptions : Hash(String, KlassDoc), title : String, version : String, openapi : String = OPENAPI_VERSIONS[0], composition : Composition = Composition.default, **info)
    raise ArgumentError.new("unsupported OpenAPI version #{openapi}, expected #{OPENAPI_VERSIONS.join(" or ")}") unless openapi.in?(OPENAPI_VERSIONS)
    # 3.0 uses its own dialect of JSON Schema, 3.1 uses JSON Schema 2020-12
    openapi_3_0 = openapi == "3.0.3"

    # expanded when the method is used, once all the routes are known
    {% begin %}
      # build the OpenAPI document

      # Class => Schema (and request types)
      response_types = {} of String => String
      # nested JSON::Serializable types and enums are referenced, defined once as components
      definitions = ::JSON::Schema::Definitions.new("#/components/schemas/")
      # Route => {array?, Class} => Response code
      route_response = Hash(String, Hash(Tuple(Bool, String), Int32)).new do |hash, key|
        hash[key] = {} of Tuple(Bool, String) => Int32
      end

      # convert all the response types into JSON schema that can be referenced and map the routes to them
      # * default response will include all the other responses types (split up and differentiate)
      # * ignore array types (need to reference the internal type [if possible])
      {% for route_key, details in Route::Builder::OPENAPI_ROUTES %}
        {% if !details[:mcp_prompt] && Base::CONCRETE_CONTROLLERS[details[:controller].id] %}
        {% default_type = details[:default_response][0].resolve %}
        {% default_code = details[:default_response][1] %}
        {% default_specified = details[:default_response][2] %}

        {% request_body = details[:request_body].id %}
        {% if request_body.stringify != "Nil" %}
          add_schema(response_types, definitions, {{request_body.stringify}}, introspect_schema({{ request_body }}))
        {% end %}

        {% responses = {} of Nil => Nil %}

        # we need to work out what types are default responses versus the specified ones
        {% if default_specified && default_type.union? && !details[:responses].empty? %}
          {% default_types = default_type.union_types %}
          {% for klass, response_code in details[:responses] %}
            {% klass = klass.resolve %}
            {% configure_types = klass.union? ? klass.union_types : [klass] %}
            {% for response_klass in configure_types %}
              {% default_types = default_types.reject { |type| type == response_klass } %}
              {% responses[response_klass] = response_code %}
            {% end %}
          {% end %}
          {% for klass in default_types %}
            {% responses[klass] = default_code %}
          {% end %}
        {% elsif !details[:responses].empty? %}
          {% responses = details[:responses] %}
        {% elsif default_specified %}
          {% responses[default_type] = default_code %}
        {% else %}
          {% responses[Nil] = default_code %}
        {% end %}

        {% for klass, response_code in responses %}
          {% resolved_klass = klass.resolve %}
          {% is_array = false %}
          {% if !resolved_klass.union? && resolved_klass.stringify.starts_with?("Array(") %}
            {% is_array = true %}
            {% resolved_klass = resolved_klass.type_vars[0] %}
          {% end %}

          {% if resolved_klass != Nil %}
            add_schema(response_types, definitions, {{resolved_klass.stringify}}, introspect_schema({{ resolved_klass }}))
          {% end %}
          route_response[{{route_key}}][{ {{is_array}}, {{resolved_klass.stringify}} }] = ({{response_code}}).to_i
        {% end %}
        {% end %}
      {% end %}

      {% for exception_key, details in Route::Builder::OPENAPI_ERRORS %}
        {% default_type = details[:default_response][0].resolve %}
        {% default_code = details[:default_response][1] %}
        {% default_specified = details[:default_response][2] %}

        {% responses = {} of Nil => Nil %}

        # we need to work out what types are default responses versus the specified ones
        {% if default_specified && default_type.union? && !details[:responses].empty? %}
          {% default_types = default_type.union_types %}
          {% for klass, response_code in details[:responses] %}
            {% default_types = default_types - [klass.resolve] %}
            {% responses[klass] = response_code %}
          {% end %}
          {% for klass in default_types %}
            {% responses[klass] = default_code %}
          {% end %}
        {% elsif !details[:responses].empty? %}
          {% responses = details[:responses] %}
        {% elsif default_specified %}
          {% responses[default_type] = default_code %}
        {% else %}
          {% responses[Nil] = default_code %}
        {% end %}

        {% for klass, response_code in responses %}
          {% resolved_klass = klass.resolve %}
          {% is_array = false %}
          {% if !resolved_klass.union? && resolved_klass.stringify.starts_with?("Array(") %}
            {% is_array = true %}
            {% resolved_klass = resolved_klass.type_vars[0] %}
          {% end %}

          {% if resolved_klass != Nil %}
            add_schema(response_types, definitions, {{resolved_klass.stringify}}, introspect_schema({{ resolved_klass }}))
          {% end %}
          route_response[{{exception_key}}][{ {{is_array}}, {{resolved_klass.stringify}} }] = ({{response_code}}).to_i
        {% end %}
      {% end %}

      filters = {
        {% for filter_key, details in Route::Builder::OPENAPI_FILTERS %}
          {% params = details[:params] %}
          {{filter_key}} => {
            controller: {{ details[:controller] }},
            method: {{ details[:method] }},
            wrapper_method: {{ details[:wrapper_method] }},
            filter_key: {{ filter_key }},
            request_body: {{ details[:request_body].id.stringify }},
            params: [
              {% for param_name, param in params %}
                {
                  name: {{ param_name }},
                  in: {{ param[:in] }},
                  required: ({{ param[:required] ? true : nil }}).as(Bool?),
                  schema: introspect_schema({{ param[:schema] }}).to_json,
                  docs: {{ param[:docs] }}.as(String?),
                  example: {{ param[:example] }}.as(String?),
                },
              {% end %}
            ]{% if params.empty? %} of Params{% end %},
          },
        {% end %}
      }{% if Route::Builder::OPENAPI_FILTERS.empty? %} of String => Filter{% end %}

      exceptions = {
        {% for exception_key, details in Route::Builder::OPENAPI_ERRORS %}
          {{exception_key}} => {
            method: {{ details[:method] }},
            controller: {{ details[:controller] }},
            exception_name: {{ details[:exception] }},
            exception_key: {{ exception_key }},
            responses: route_response[{{exception_key}}]
          },
        {% end %}
      }{% if Route::Builder::OPENAPI_ERRORS.empty? %} of String => ExceptionHandler{% end %}

      # for exceptions and filters we will need to:
      # * collect all the matching methods / exceptions
      # * run down the class ancestors to find the matching class
      # * this gives us Class+method match as might be multiple filters with the same function name

      routes = {} of String => RouteDetails
      {% for route_key, details in Route::Builder::OPENAPI_ROUTES %}
        {% if !details[:mcp_prompt] && Base::CONCRETE_CONTROLLERS[details[:controller].id] %}
        # the filters applied to this route
        {% filters = Base::OPENAPI_FILTER_MAP[route_key] %}
        {% errors = Base::OPENAPI_ERRORS_MAP[route_key] %}

        route_filters = {{filters}}{% if filters.empty? %} of String{% end %}
        route_errors = {{errors}}{% if errors.empty? %} of String{% end %}
        route_class = {{ details[:controller] }}
        class_description, filter_keys, error_keys = find_matching(descriptions, route_class, filters, exceptions, route_filters, route_errors)

        {% params = details[:params] %}

        routes[{{route_key}}] = {
          route_lookup: {{route_key}},
          verb: {{ details[:verb] }},
          route: {{ details[:route] }},
          params: [
            {% for param_name, param in params %}
              {
                name: {{ param[:header] || param_name }},
                in: {{ param[:in] }},
                required: ({{ param[:required] ? true : nil }}).as(Bool?),
                schema: introspect_schema({{ param[:schema] }}).to_json,
                docs: {{ param[:docs] }}.as(String?),
                example: {{ param[:example] }}.as(String?),
              },
            {% end %}
          ]{% if params.empty? %} of Params{% end %},
          original_params: [] of Params,
          method: {{ details[:method] }},
          filters: filter_keys,
          error_handlers: error_keys,
          controller: {{ details[:controller] }},
          request_body: {{ details[:request_body].id.stringify }},
          route_responses: route_response[{{route_key}}]
        }
        {% end %}
      {% end %}

      #{
      #  descriptions: descriptions,
      #  routes: routes,
      #  exceptions: exceptions,
      #  filters: filters,
      #  response_types: response_types,
      #}.to_yaml
      accepts = {{ ActionController::Route::Builder::PARSERS.keys }}
      responders = {{ ActionController::Route::Builder::RESPONDERS.keys }}

      generate_openapi_doc(title, version, info, descriptions, placed_routes(routes, composition), exceptions, filters, response_types, accepts, responders, definitions, openapi)
      {% end %}
  end

  # :nodoc:
  def placed_routes(routes : Hash(String, RouteDetails), composition : Composition) : Hash(String, RouteDetails)
    placed = {} of String => RouteDetails
    composition.placements.each_with_index do |placement, index|
      routes.each do |key, route|
        next unless route[:controller] == placement.controller.name
        path = placement.path(route[:route])
        path_names = path.split('/').select { |segment| segment.starts_with?(':') || segment.starts_with?("?:") || segment.starts_with?("*:") }.map { |segment| segment.split(':', 2)[1] }
        parameters = route[:params].compact_map do |param|
          if param[:in] == :path && !path_names.includes?(param[:name])
            next if param[:schema] == %({"type":"null"})
            {name: param[:name], in: :query, required: param[:required], schema: param[:schema], docs: param[:docs], example: param[:example]}
          elsif param[:in] == :query && path_names.includes?(param[:name])
            {name: param[:name], in: :path, required: param[:required], schema: param[:schema], docs: param[:docs], example: param[:example]}
          else
            param
          end
        end
        path.split('/').each do |segment|
          next unless segment.starts_with?(':') || segment.starts_with?("?:") || segment.starts_with?("*:")
          name = segment.split(':', 2)[1]
          next if parameters.any? { |param| param[:in] == :path && param[:name] == name }
          parameters << {
            name:     name,
            in:       :path,
            required: segment.starts_with?(':') ? true.as(Bool?) : nil.as(Bool?),
            schema:   %({"type":"null"}),
            docs:     nil.as(String?),
            example:  nil.as(String?),
          }
        end
        placed["#{index}:#{key}"] = route.merge(route: path, params: parameters, original_params: route[:params])
      end
    end
    placed
  end

  # :nodoc:
  # referenced types are defined by `definitions`, the rest are components in their own right
  def add_schema(response_types : Hash(String, String), definitions : JSON::Schema::Definitions, klass : String, schema) : Nil
    response_types[klass] = schema.to_json unless definitions.reference?(schema)
  end

  # :nodoc:
  # the component name of a type, shared with the referenced definitions so names never clash
  def normalise_schema_reference(class_name)
    JSON::Schema::Definitions.normalise(class_name)
  end

  # :nodoc:
  # converts a route, `/users/:id`, into OpenAPI format, `/users/{id}`
  def openapi_path(route : String) : String
    route.split('/').join('/') do |i|
      case i
      when .starts_with?(':')
        "{#{i.lstrip(':')}}"
      when .starts_with?("?:")
        "{#{i.lstrip("?:")}}"
      when .starts_with?("*:")
        "{#{i.lstrip("*:")}}"
      else
        i
      end
    end
  end

  # :nodoc:
  def generate_openapi_doc(title : String, version : String, info, descriptions, routes, exceptions, filters, response_types, accepts, responders, definitions : JSON::Schema::Definitions = JSON::Schema::Definitions.new("#/components/schemas/"), openapi : String = OPENAPI_VERSIONS[0])
    info = info.merge({
      title:   title,
      version: version,
    })
    components = Components.new
    schemas = components.schemas

    operation_ids = Set(String).new

    # add all the schemas
    definitions.resolve.each do |name, schema|
      if (schema_docs = definitions.type_name(name).try { |klass| descriptions[klass]?.try(&.docs) }) && (properties = schema.as_h?)
        schema = JSON::Any.new(properties.merge({"description" => JSON::Any.new(schema_docs)}))
      end
      schemas[name] = schema
    end

    response_types.each do |klass, schema|
      if schema_docs = descriptions[klass]?.try(&.docs)
        schema = %(#{schema[0..-2]},"description":#{schema_docs.to_json}})
      end
      begin
        schemas[normalise_schema_reference(klass)] = JSON.parse(schema)
      rescue JSON::ParseException
        puts "WARN: failed to parse class schema '#{schema}'"
      end
    end

    paths = Hash(String, Path).new { |hash, key| hash[key] = Path.new }

    routes.each do |route_key, route|
      verb = route[:verb]

      operation = Operation.new
      path_summary = path_description = nil

      # see if we have some documentation for the controller
      if controller_docs = descriptions[route[:controller]]?
        if docs = controller_docs.docs
          doc_lines = docs.split("\n", 2)
          path_summary = doc_lines[0].strip
          path_description = docs.strip if doc_lines.size > 1
        end

        # grab the documentation for the route
        docs = controller_docs.methods[route[:method]]?

        # might have to check for docs in the ancestor classes
        unless docs
          controller_docs.ancestors.each do |ancestor_klass|
            docs = descriptions[ancestor_klass]?.try(&.methods[route[:method]]?)
            break if docs
          end
        end

        if docs
          doc_lines = docs.split("\n", 2)
          operation.summary = doc_lines[0].strip
          operation.description = docs.strip if doc_lines.size > 1
        end
      end

      op_id = "#{route[:controller]}_#{route[:method]}"
      operation.tags << route[:controller].split("::")[-1]

      # track request body, filter might be parsing it
      raw_req_body = route[:request_body]

      # assemble the list of params
      params = route[:params].map do |raw_param|
        param = Parameter.new
        param.name = raw_param[:name]
        param.in = raw_param[:in].to_s
        param.required = raw_param[:required] ? true : nil
        param.schema = JSON.parse(raw_param[:schema])
        param.description = raw_param[:docs]
        param.example = raw_param[:example].try { |example| JSON::Any.new(example) }
        if param.in == "path" && (original = route[:original_params].find { |source| source[:name] == param.name && source[:in] == :query })
          fallback = param.dup
          fallback.in = "query"
          fallback.required = original[:required] ? true : nil
          param.query_fallback = fallback
        end
        param
      end

      route[:filters].each do |filter_key|
        filter = filters[filter_key]?
        next unless filter

        if raw_req_body == "Nil"
          raw_req_body = filter[:request_body] if filter[:request_body] != "Nil"
        end

        filter[:params].each do |raw_param|
          param_name = raw_param[:name]
          existing = params.find { |current_param| current_param.name == param_name }
          if existing
            if existing.schema.try(&.[]?("type")) == "null"
              existing.schema = JSON.parse(raw_param[:schema])
              existing.description ||= raw_param[:docs]
              existing.example ||= raw_param[:example].try { |example| JSON::Any.new(example) }
            end
            if existing.in == "path" && raw_param[:in] == :query
              fallback = existing.query_fallback || existing.dup
              fallback.in = "query"
              fallback.required = fallback.required || raw_param[:required] ? true : nil
              existing.query_fallback = fallback
            end
            next
          end

          param = Parameter.new
          param.name = param_name
          param.in = raw_param[:in].to_s
          param.required = raw_param[:required] ? true : nil
          param.schema = JSON.parse(raw_param[:schema])
          param.description = raw_param[:docs]
          param.example = raw_param[:example].try { |example| JSON::Any.new(example) }
          params << param
        end
      end

      params.each do |param|
        schema = param.schema
        if param.in == "path"
          # path params are always required, an untyped one is a string
          param.required = true
          param.schema = JSON::Any.new({"type" => JSON::Any.new("string")}) if schema.nil? || schema["type"]? == "null"
        elsif param.in == "query" && schema_type(schema, schemas) == "array"
          # array params are a single comma separated value
          param.style = "form"
          param.explode = false
        end

        if example = param.example.try(&.as_s?)
          param.example = typed_example(example, param.schema, schemas) || param.example
        end
        if fallback = param.query_fallback
          fallback.example = param.example
          if schema_type(fallback.schema, schemas) == "array"
            fallback.style = "form"
            fallback.explode = false
          end
        end
      end
      operation.parameters = params

      # see if there is any requirement for a request body
      if raw_req_body != "Nil"
        req_body = build_response(accepts, false, raw_req_body, nil)
        req_body.required = true
        operation.request_body = req_body
      end

      # assemble the list of responses
      route[:route_responses].each do |(is_array, klass_name), response_code|
        operation.responses[response_code.to_s] = build_response(responders, is_array, klass_name, response_code)
      end

      route[:error_handlers].each do |error_handler|
        handler = exceptions[error_handler]
        handler[:responses]?.try &.each do |(is_array, klass_name), response_code|
          operation.responses[response_code.to_s] = build_response(responders, is_array, klass_name, response_code)
        end
      end

      # the full route keeps the operation id, the router also matches it without its optional segments
      variants = Router::RouteHandler.optional_variants(route[:route], glob: true)
      variants.sort_by! { |(_variant, omitted)| omitted ? 1 : 0 }
      variants.each do |(variant, omitted)|
        path_key = openapi_path(variant)
        variant_operation = operation
        if omitted
          present = path_key.scan(/\{([^}]+)\}/).map(&.[1])
          variant_operation = operation.dup
          variant_operation.parameters = params.compact_map do |param|
            param.in == "path" && !present.includes?(param.name) ? param.query_fallback : param
          end
        end
        variant_operation.operation_id = unique_operation_id(operation_ids, omitted ? "#{op_id}_without_#{omitted}" : op_id)

        path = paths[path_key]
        path.summary = path_summary if path_summary
        path.description = path_description if path_description

        case verb
        when "get"
          path.get = variant_operation
        when "put"
          path.put = variant_operation
        when "post"
          path.post = variant_operation
        when "patch"
          path.patch = variant_operation
        when "delete"
          path.delete = variant_operation
        when "websocket"
          path.get = variant_operation
        end
      end
    end

    {
      openapi:    openapi,
      info:       info,
      paths:      paths,
      components: components,
    }
  end

  # :nodoc:
  # operation ids must be unique, a repeat gets the first free numbered suffix
  def unique_operation_id(used : Set(String), operation_id : String) : String
    unique = operation_id
    index = 1
    while used.includes?(unique)
      index += 1
      unique = "#{operation_id}_#{index}"
    end
    used << unique
    unique
  end

  private SCHEMA_REFERENCE = "#/components/schemas/"

  # :nodoc:
  # the type of a schema, following references
  def schema_type(schema : JSON::Any?, schemas : Hash(String, JSON::Any), depth : Int32 = 0) : String?
    return unless schema && (hash = schema.as_h?) && depth < 16
    if type = json_type(hash)
      type
    elsif ref = hash["$ref"]?.try(&.as_s?)
      schema_type(schemas[ref.lchop(SCHEMA_REFERENCE)]?, schemas, depth + 1)
    elsif members = (hash["allOf"]? || hash["anyOf"]?).try(&.as_a?)
      members.each do |member|
        type = schema_type(member, schemas, depth + 1)
        return type if type
      end
      nil
    end
  end

  # :nodoc:
  # the `type` of a schema, the first that isn't null when it's a list (`["integer", "null"]`)
  def json_type(schema : Hash(String, JSON::Any)) : String?
    type = schema["type"]?
    type.try(&.as_s?) || type.try(&.as_a?).try(&.compact_map(&.as_s?).find(&.!=("null")))
  end

  # :nodoc:
  # parameter examples are written as they appear in a URL, this converts them to the type
  # of the schema. `nil` if the example doesn't match the schema
  def typed_example(example : String, schema : JSON::Any?, schemas : Hash(String, JSON::Any), depth : Int32 = 0) : JSON::Any?
    return unless schema && (hash = schema.as_h?) && depth < 16

    case json_type(hash)
    when "integer"
      example.to_i64?.try { |value| JSON::Any.new(value) }
    when "number"
      example.to_f64?.try { |value| JSON::Any.new(value) }
    when "boolean"
      JSON::Any.new(example == "true") if example.in?("true", "false")
    when "array"
      items = [] of JSON::Any
      example.split(',').each do |item|
        next if (item = item.strip).empty?
        return unless typed = typed_example(item, hash["items"]?, schemas, depth + 1)
        items << typed
      end
      JSON::Any.new(items)
    when "string"
      JSON::Any.new(example)
    else
      if ref = hash["$ref"]?.try(&.as_s?)
        typed_example(example, schemas[ref.lchop(SCHEMA_REFERENCE)]?, schemas, depth + 1)
      elsif members = (hash["allOf"]? || hash["anyOf"]?).try(&.as_a?)
        members.each do |member|
          typed = typed_example(example, member, schemas, depth + 1)
          return typed if typed
        end
        nil
      end
    end
  end

  # :nodoc:
  def build_response(responders, is_array, klass_name, response_code)
    response = Response.new

    if response_code
      status_code = HTTP::Status.from_value(response_code)
      response.description = status_code.description || status_code.to_s
    end

    if klass_name != "Nil"
      ref_klass = normalise_schema_reference(klass_name)
      schema = if is_array
                 Schema.new(%({"type":"array","items":{"$ref":"#/components/schemas/#{ref_klass}"}}))
               else
                 Schema.new(Reference.new("#/components/schemas/#{ref_klass}").to_json)
               end

      accept_schemas = {} of String => Schema
      responders.each do |acceptable|
        case acceptable
        when "application/json"
          accept_schemas[acceptable] = schema
        when "application/yaml"
          accept_schemas[acceptable] = schema
        when .starts_with?("text/")
          accept_schemas[acceptable] = Schema.new(%({"type":"string"}))
        else
          accept_schemas[acceptable] = Schema.new(%({"type":"string","format":"binary"}))
        end
      end

      response.content = accept_schemas
    end

    response
  end
end
