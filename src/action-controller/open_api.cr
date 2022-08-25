require "json-schema"
require "yaml"

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
  end

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

  macro finished
    def generate_open_api_docs
      descriptions = extract_route_descriptions

      # NOTE:: for exceptions and filters we will need to run down the class ancestors
      # to check for any matches

      routes = [
        {% for route_key, details in Route::Builder::OPENAPI_ROUTES %}
          # the filters applied to this route
          {% filters = Base::OPENAPI_FILTER_MAP[route_key] %}
          {% errors = Base::OPENAPI_ERRORS_MAP[route_key] %}

          {% params = details[:params] %}
          {
            route_lookup: {{route_key}},
            verb: {{ details[:verb] }},
            route: {{ details[:route] }},
            params: [
              {% for param_name, param in params %}
                {
                  name: {{ param_name }},
                  in: {{ param[:in] }},
                  required: {{ param[:required] }},
                  schema: ::JSON::Schema.introspect({{ param[:schema] }})
                },
              {% end %}
            ]{% if params.empty? %} of NamedTuple(name: String, in: Symbol, required: Bool, schema: String){% end %},
            method: {{ details[:method] }},
            filters: {{filters}}{% if filters.empty? %} of String{% end %},
            error_handlers: {{errors}}{% if errors.empty? %} of String{% end %},
            controller: {{ details[:controller] }},
            request_body: {{ details[:request_body] && details[:request_body].stringify || "Nil" }},
            default_response: {
              {{ details[:default_response][0] }},
              ( {{ details[:default_response][1] }} ).to_i
            },
            responses: {
              {% for klass, response_code in details[:responses] %}
                {{ klass }} => ({{response_code}}).to_i,
              {% end %}
            }{% if details[:responses].empty? %} of String => Int32 {% end %},
          },
        {% end %}
      ]{% if Route::Builder::OPENAPI_ROUTES.empty? %} of Nil{% end %}

      exceptions = {
        {% for exception_key, details in Route::Builder::OPENAPI_ERRORS %}
        {{exception_key}} => {
            method: {{ details[:method] }},
            controller: {{ details[:controller] }},
            exception_name: {{ details[:exception] }},
            default_response: {
              {{ details[:default_response][0] }},
              ( {{ details[:default_response][1] }} ).to_i
            },
            responses: {
              {% for klass, response_code in details[:responses] %}
                {{ klass }} => ({{response_code}}).to_i,
              {% end %}
            }{% if details[:responses].empty? %} of String => Int32 {% end %},
          },
        {% end %}
      }{% if Route::Builder::OPENAPI_ERRORS.empty? %} of Nil => Nil{% end %}

      filters = {
        {% for filter_key, details in Route::Builder::OPENAPI_FILTERS %}
          {% params = details[:params] %}
          {{filter_key}} => {
            controller: {{ details[:controller] }},
            method: {{ details[:method] }},
            wrapper_method: {{ details[:wrapper_method] }},
            params: [
              {% for param_name, param in params %}
                {
                  name: {{ param_name }},
                  in: {{ param[:in] }},
                  required: {{ param[:required] }},
                  schema: ::JSON::Schema.introspect({{ param[:schema] }})
                },
              {% end %}
            ]{% if params.empty? %} of NamedTuple(name: String, in: Symbol, required: Bool, schema: String){% end %},
          },
        {% end %}
      }{% if Route::Builder::OPENAPI_FILTERS.empty? %} of Nil => Nil{% end %}

      {
        descriptions: descriptions,
        routes: routes,
        exceptions: exceptions,
        filters: filters,
      }.to_yaml
    end
  end
end
