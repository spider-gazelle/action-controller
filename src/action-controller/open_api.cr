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
      type["ancestors"]?.try &.as_a.each do |klass|
        if klass["full_name"].as_s == "ActionController::Base"
          save_methods = true
          break
        end
      end
      next unless save_methods

      # save the instance method docs
      type["instance_methods"]?.try &.as_a.each do |method|
        if doc = method["doc"]?
          klass_docs.methods[method["name"].as_s] = doc.as_s
        end
      end
    end

    docs
  end

  macro finished
    def generate_open_api_docs
      descriptions = extract_route_descriptions

      routes = [
        {% for route, details in ActionController::Route::Builder::OPENAPI_ROUTERS %}
          {% params = details[:params] %}
          {
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
            controller: {{ details[:controller] }},
          },
        {% end %}
      ]{% if ActionController::Route::Builder::OPENAPI_ROUTERS.empty? %} of Nil{% end %}

      {
        descriptions: descriptions,
        routes: routes,
      }.to_yaml
    end
  end
end
