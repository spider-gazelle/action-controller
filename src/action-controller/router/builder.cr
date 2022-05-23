annotation Route::GET
end

abstract struct Route::Param::Conversion
  abstract def initialize(raw : String)
  abstract def value

  def value!
    val = value
    raise "is nil" unless val
    val
  end
end

struct Route::Param::ConvertInt32 < Route::Param::Conversion
  def initialize(@raw : String)
  end

  def value : Int32?
    @raw.to_i?
  end
end

struct Route::Param::ConvertString < Route::Param::Conversion
  def initialize(raw : String)
    @value = raw
  end

  getter value

  def value!
    value
  end
end

module Route::Builder
  macro __parse_inferred_routes__
    {% for method in @type.methods %}
      {% for ann, idx in method.annotations(Route::GET) %}
        # TODO:: use annotations to specify content type
        # raise if there is a block
        # if no restriction defined, default to String?
        {% route_params = (NAMESPACE[0] + ann[0]).split("/").select { |part| part.starts_with?(":") || part.starts_with?("?:") || part.starts_with?("*:") }.map { |part| part.split(":")[1] } %}
        get {{ann[0]}},  :__{{method.name.id}}_wrapper__ do
          {% if method.args.empty? %}
            result = {{method.name.id}}
          {% else %}
            args = {
              {% for arg in method.args %}
                {% string_name = arg.name.id.stringify %}
                {% if route_params.includes? string_name %} # TODO:: check if this is optional or a splat
                  {{arg.name.id}}: ::Route::Param::Convert{{arg.restriction}}.new(route_params[{{string_name}}]).value!
                {% else %}
                  {{arg.name.id}}: ::Route::Param::Convert{{arg.restriction}}.new(params[{{string_name}}]).value! # arg.default_value
                {% end %}
              {% end %}
            }
            result = {{method.name.id}}(**args)
          {% end %}
          render(json: result) unless @render_called
        end
      {% end %}
    {% end %}
	end

  macro included
    macro inherited
      macro finished
        __parse_inferred_routes__
      end
    end
	end
end
