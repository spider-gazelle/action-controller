require "uri"
require "yaml"
require "./open_api/*"

module ActionController::OpenAPI
  extend self

  alias Params = NamedTuple(
    name: String,
    in: Symbol,
    required: Bool,
    schema: String,
    docs: String?,
    example: String?)

  alias Filter = NamedTuple(
    controller: String,
    method: String,
    wrapper_method: String,
    filter_key: String,
    params: Array(Params))

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
    route_responses: Hash(Tuple(Bool, String), Int32))

  SAVE_DESCRIPTIONS_OF = {"ActionController::Base", "JSON::Serializable", "YAML::Serializable"}

  def extract_all_types(type_collection, current_list)
    type_collection.concat current_list
    current_list.each do |current_type|
      if next_list = current_type["types"]?.try &.as_a
        extract_all_types(type_collection, next_list)
      end
    end
  end

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
    def generate_open_api_docs(title : String, version : String, **info)
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
          response_types[{{request_body.stringify}}] = ::JSON::Schema.introspect({{ request_body }}, openapi: true).to_json
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
            response_types[{{resolved_klass.stringify}}] = ::JSON::Schema.introspect({{ resolved_klass }}, openapi: true).to_json
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
            response_types[{{resolved_klass.stringify}}] = ::JSON::Schema.introspect({{ resolved_klass }}, openapi: true).to_json
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
                  schema: ::JSON::Schema.introspect({{ param[:schema] }}, openapi: true).to_json,
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
                schema: ::JSON::Schema.introspect({{ param[:schema] }}, openapi: true).to_json,
                docs: {{ param[:docs] }}.as(String?),
                example: {{ param[:example] }}.as(String?),
              },
            {% end %}
          ]{% if params.empty? %} of Params{% end %},
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

      generate_openapi_doc(title, version, info, descriptions, routes, exceptions, filters, response_types, accepts, responders)
    end
  end

  def normalise_schema_reference(class_name)
    class_name.gsub(' ', '.').gsub(/[^0-9a-zA-Z_]/, '_')
  end

  def generate_openapi_doc(title : String, version : String, info, descriptions, routes, exceptions, filters, response_types, accepts, responders)
    info = info.merge({
      title:   title,
      version: version,
    })
    components = Components.new
    schemas = components.schemas

    operation_id = Hash(String, Int32).new { |hash, key| hash[key] = 0 }

    # add all the schemas
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
      path_key = route[:route]
      verb = route[:verb]

      # ensure the path is in OpenAPI format
      path_key = path_key.split('/').join('/') do |i|
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

      # grab the path object
      path = paths[path_key]
      operation = Operation.new

      # see if we have some documentation for the controller
      if controller_docs = descriptions[route[:controller]]?
        if docs = controller_docs.docs
          doc_lines = docs.split("\n", 2)
          path.summary = doc_lines[0]
          path.description = docs if doc_lines.size > 1
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
          operation.summary = doc_lines[0]
          operation.description = docs if doc_lines.size > 1
        end
      end

      # ensure we have a unique operation id
      op_id = "#{route[:controller]}##{route[:method]}"
      index = operation_id[op_id] + 1
      operation.operation_id = index > 1 ? "#{op_id}{#{index}}" : op_id
      operation_id[op_id] = index
      operation.tags << route[:controller].split("::")[-1]

      # see if there is any requirement for a request body
      if route[:request_body] != "Nil"
        req_body = build_response(accepts, false, route[:request_body], nil)
        req_body.required = true
        operation.request_body = req_body
      end

      # assemble the list of params
      params = route[:params].map do |raw_param|
        param = Parameter.new
        param.name = raw_param[:name]
        param.in = raw_param[:in].to_s
        param.required = raw_param[:required]
        param.schema = JSON.parse(raw_param[:schema])
        param.description = raw_param[:docs]
        param.example = raw_param[:example]
        param
      end

      route[:filters].each do |filter_key|
        filter = filters[filter_key]?
        next unless filter

        filter[:params].each do |raw_param|
          param_name = raw_param[:name]
          existing = params.find { |current_param| current_param.name == param_name }
          if existing
            if existing.schema.try(&.[]?("type")) == "null"
              existing.schema = JSON.parse(raw_param[:schema])
              existing.description ||= raw_param[:docs]
              existing.example ||= raw_param[:example]
            end
            next
          end

          param = Parameter.new
          param.name = param_name
          param.in = raw_param[:in].to_s
          param.required = raw_param[:required]
          param.schema = JSON.parse(raw_param[:schema])
          param.description = raw_param[:docs]
          param.example = raw_param[:example]
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
        handler[:responses]?.try &.each do |(is_array, klass_name), response_code|
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
      openapi:    "3.0.3",
      info:       info,
      paths:      paths,
      components: components,
    }
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
