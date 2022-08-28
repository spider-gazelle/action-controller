require "uri"
require "yaml"
require "./open_api/*"

module ActionController::OpenAPI
  extend self

  struct KlassDoc
    include JSON::Serializable
    include YAML::Serializable

    def initialize(@name, @docs : String?)
    end

    getter name : String
    getter docs : String?

    getter methods : Hash(String, String) = {} of String => String
    getter ancestors : Array(String) = [] of String

    def implements?(filter)
      filter_klass = filter[:controller]
      filter_klass == name || ancestors.includes?(filter_klass)
    end
  end

  alias Params = NamedTuple(
    name: String,
    in: Symbol,
    required: Bool,
    schema: String
  )

  alias Filter = NamedTuple(
    controller: String,
    method: String,
    wrapper_method: String,
    filter_key: String,
    params: Array(Params)
  )

  alias ExceptionHandler = NamedTuple(
    method: String,
    controller: String,
    exception_name: String,
    exception_key: String,
  )

  alias RouteDetails = NamedTuple(
    route_lookup: String,
    verb: String,
    route: String,
    params: Array(Params),
    method: String,
    filters: Array(String),
    error_handlers: Array(String),
    controller: String,
    request_body: String,
    route_responses: Hash(Tuple(Bool, String), Int32)
  )

  def extract_route_descriptions
    output = IO::Memory.new

    status = Process.run(
      "crystal",
      args: {"docs", "--format=json"},
      output: output
    )

    raise "failed to obtain route descriptions via 'crystal docs'" unless status.success?

    program_types = JSON.parse(output.to_s)["program"]["types"].as_a
    docs = {} of String => KlassDoc

    program_types.each do |type|
      klass_docs = KlassDoc.new(type["name"].as_s, type["doc"]?.try &.as_s)
      docs[klass_docs.name] = klass_docs

      # check if we want the method docs of this class
      save_methods = false
      modules = [] of String
      ancestors = [] of String
      type["ancestors"]?.try &.as_a.each do |klass|
        full_name = klass["full_name"].as_s
        if full_name == "ActionController::Base"
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

  def find_matching(
    klass_descriptions : Hash(String, KlassDoc),
    controller : String,
    all_filters,
    all_exceptions,
    route_filters : Array(String),
    route_errors : Array(String)
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

  macro finished
    def generate_open_api_docs
      descriptions = extract_route_descriptions

      # build the OpenAPI document

      # Class => Schema (and request types)
      response_types = {} of String => String
      # Route => {array?, Class} => Response code
      route_response = Hash(String, Hash(Tuple(Bool, String), Int32)).new do |hash, key|
        hash[key] = {} of Tuple(Bool, String) => Int32
      end

      # convert all the response types into JSON schema that can be referenced and map the routes to them
      # * default response will include all the other responses types (split up and differentiate)
      # * ignore array types (need to reference the internal type [if possible])
      {% for route_key, details in Route::Builder::OPENAPI_ROUTES %}
        {% default_type = details[:default_response][0].resolve %}
        {% default_code = details[:default_response][1] %}
        {% default_specified = details[:default_response][2] %}

        {% request_body = details[:request_body].id %}
        {% if request_body.stringify != "Nil" %}
          response_types[{{request_body.stringify}}] = ::JSON::Schema.introspect({{ request_body }}).to_json
        {% end %}

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
            response_types[{{resolved_klass.stringify}}] = ::JSON::Schema.introspect({{ resolved_klass }}).to_json
          {% end %}
          route_response[{{route_key}}][{ {{is_array}}, {{resolved_klass.stringify}} }] = ({{response_code}}).to_i
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
            response_types[{{resolved_klass.stringify}}] = ::JSON::Schema.introspect({{ resolved_klass }}).to_json
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
            params: [
              {% for param_name, param in params %}
                {
                  name: {{ param_name }},
                  in: {{ param[:in] }},
                  required: {{ param[:required] }},
                  schema: ::JSON::Schema.introspect({{ param[:schema] }}).to_json
                },
              {% end %}
            ]{% if params.empty? %} of Param{% end %},
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
                name: {{ param_name }},
                in: {{ param[:in] }},
                required: {{ param[:required] }},
                schema: ::JSON::Schema.introspect({{ param[:schema] }}).to_json
              },
            {% end %}
          ]{% if params.empty? %} of NamedTuple(name: String, in: Symbol, required: Bool, schema: String){% end %},
          method: {{ details[:method] }},
          filters: filter_keys,
          error_handlers: error_keys,
          controller: {{ details[:controller] }},
          request_body: {{ details[:request_body].id.stringify }},
          route_responses: route_response[{{route_key}}]
        }
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

      generate_openapi_doc(descriptions, routes, exceptions, filters, response_types, accepts, responders)
    end
  end

  def normalise_schema_reference(class_name)
    class_name.gsub(' ', '.').gsub(/[^0-9a-zA-Z_]/, '_')
  end

  def generate_openapi_doc(descriptions, routes, exceptions, filters, response_types, accepts, responders)
    version = "3.0.1"
    info = {
      title: "Spider Gazelle",
      version: ActionController::VERSION
    }
    components = Components.new
    schemas = components.schemas

    operation_id = Hash(String, Int32).new { |hash, key| hash[key] = 0 }

    # add all the schemas
    response_types.each do |klass, schema|
      schemas[normalise_schema_reference(klass)] = JSON.parse(schema)
    end

    paths = Hash(String, Path).new { |hash, key| hash[key] = Path.new }

    routes.each do |route_key, route|
      path_key = route[:route]
      verb = route[:verb]

      # ensure the path is in OpenAPI format
      path_key = path_key.split('/').join('/') do |i|
        if i.starts_with?(':')
          "{#{i.lstrip(':')}}"
        else
          i
        end
      end

      # grab the path object
      path = paths[path_key]

      # see if we have some documentation for the controller
      controller_docs = descriptions[route[:controller]]?
      if docs = controller_docs.try &.docs
        doc_lines = docs.split("\n", 2)
        path.summary = doc_lines[0]
        path.description = docs if doc_lines.size > 1
      end

      # grab the documentation for the route
      operation = Operation.new
      if docs = controller_docs.try &.methods[route[:method]]?
        doc_lines = docs.split("\n", 2)
        operation.summary = doc_lines[0]
        operation.description = docs if doc_lines.size > 1
      end

      # ensure we have a unique operation id
      op_id = "#{route[:controller]}##{route[:method]}"
      index = operation_id[op_id] + 1
      operation.operation_id = index > 1 ? "#{op_id}{#{index}}" : op_id
      operation_id[op_id] = index

      # see if there is any requirement for a request body
      if route[:request_body] != "Nil"
        operation.request_body = build_response(accepts, false, route[:request_body], nil)
        operation.request_body.not_nil!.required = true
      end

      # assemble the list of params
      params = route[:params].map do |raw_param|
        param = Parameter.new
        param.name = raw_param[:name]
        param.in = raw_param[:in].to_s
        param.required = raw_param[:required]
        param.schema = JSON.parse(raw_param[:schema])
        param
      end

      route[:filters].each do |filter_key|
        filter = filters[filter_key]?
        next unless filter

        filter[:params].each do |raw_param|
          param_name = raw_param[:name]
          next if params.find { |existing| existing.name == param_name }

          param = Parameter.new
          param.name = param_name
          param.in = raw_param[:in].to_s
          param.required = raw_param[:required]
          param.schema = JSON.parse(raw_param[:schema])
          params << param
        end
      end
      operation.parameters = params

      # assemble the list of responses
      route[:route_responses].each do |(is_array, klass_name), response_code|
        operation.responses[response_code] = build_response(responders, is_array, klass_name, response_code)
      end

      route[:error_handlers].each do |error_handler|
        handler = exceptions[error_handler]
        handler[:responses].each do |(is_array, klass_name), response_code|
          operation.responses[response_code] = build_response(responders, is_array, klass_name, response_code)
        end
      end

      case verb
      when "get"
        path.get = operation
      when "put"
        path.put = operation
      when "post"
        path.post = operation
      when "patch"
        path.patch = operation
      when "delete"
        path.delete = operation
      when "websocket"
        path.get = operation
      end
    end

    {
      openapi: version,
      info: info,
      paths: paths,
      components: components
    }.to_yaml
  end

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
