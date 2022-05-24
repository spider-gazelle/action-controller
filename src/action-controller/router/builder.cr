require "../router"
require "./route_params"

# Create the method annotations
{% begin %}
  {% for http_method in ::ActionController::Router::HTTP_METHODS.reject(&.==("head")) %}
    annotation Route::{{http_method.upcase.id}}
    end
  {% end %}
{% end %}

module Route::Builder
  macro __parse_inferred_routes__
    # Run through the various route annotations
    {% for route_method in {Route::GET, Route::POST, Route::PUT, Route::PATCH, Route::DELETE, Route::OPTIONS} %}
      {% lower_route_method = route_method.stringify.split("::")[-1].downcase.id %}

      # Check if they have been applied to any of the methods
      {% for method in @type.methods %}

        # Multiple routes can be applied to a single method
        {% for ann, idx in method.annotations(route_method) %}
          {% method_name = method.name %}
          {% raise "#{@type}##{method_name} accepts a block which is incompatible with the router" if method.accepts_block? %}

          # Grab the response details from the annotations
          {% content_type = ann[:content_type] %}
          {% status_code = ann[:status_code] || HTTP::Status::OK %}
          {% render_type = ann[:render] || :json %}

          # Grab the param parts
          {% full_route = (NAMESPACE[0] + ann[0]).split("/") %}
          {% required_params = full_route.select(&.starts_with?(":")).map { |part| part.split(":")[1] } %}
          # {% optional_params = full_route.select(&.starts_with?("?:")).map { |part| part.split(":")[1] } %}
          # {% splat_params = full_route.select(&.starts_with?("*:")).map { |part| part.split(":")[1] } %}

          # build the standard route definition helper (get "/route", :function_name)
          {{lower_route_method}} {{ann[0]}}, :_{{method_name.id}}_wrapper_ do
            {% if method.args.empty? %}
              result = {{method_name.id}}
            {% else %}
              args = {
                {% for arg in method.args %}
                  {% string_name = arg.name.id.stringify %}

                  # Calculate the conversions required to meet the desired restrictions
                  {% if arg.restriction %}
                    # Check if restriction is optional
                    {% nilable = arg.restriction.resolve.nilable? %}

                    # Check if there are any custom converters
                    {% if custom_converter = ann[string_name + "_converter"] %}
                      {% restrictions = [custom_converter.stringify + ".new.convert(param_value)"] %}

                    # Check for custom converter arguments (assumes a single type)
                    {% elsif converter_args = ann[string_name + "_custom"] %}
                      {% union_types = arg.restriction.resolve.union_types.reject(&.nilable?) %}
                      {% restrictions = ["::Route::Param::Convert" + union_types[0].stringify + ".new(**" + converter_args.stringify + ").convert(param_value)"] %}

                    # There are a bunch of types this might be
                    {% else %}
                      {% union_types = arg.restriction.resolve.union_types.reject(&.nilable?) %}
                      {% restrictions = union_types.map { |type| "::Route::Param::Convert" + type.stringify + ".new.convert(param_value)" } %}
                    {% end %}
                  {% else %}
                    {% nilable = true %}
                    {% restrictions = ["::Route::Param::ConvertString.new.convert(param_value)"] %}
                  {% end %}

                  # Build the argument named tuple with the correct types
                  {{arg.name.id}}: (

                    # Required route param, so we ensure it
                    {% if required_params.includes? string_name %}
                      if param_value = route_params[{{string_name}}]?
                        {{restrictions.join(" || ").id}}
                      else
                        raise ::Route::Param::MissingError.new("missing required parameter", {{string_name}}, {{arg.restriction.resolve.stringify}})
                      end

                    # An optional route param, might be passed as an query param
                    {% else %}
                      if param_value = params[{{string_name}}]?
                        {{restrictions.join(" || ").id}}
                      {% if arg.default_value %}
                      else
                        {{arg.default_value}}
                      {% end %}
                      end
                    {% end %}

                  # Use tap to ensure a good error message if the function param isn't nilable
                  ){% if !nilable %}.tap { |result| raise ::Route::Param::ValueError.new("invalid parameter value", {{string_name}}, {{arg.restriction.resolve.stringify}}) if result.nil? }.not_nil!{% end %},
                {% end %}
              }

              result = {{method_name.id}}(**args)
            {% end %}

            unless @render_called
              {% if content_type %}
                @context.response.headers["Content-Type"] = {{content_type}}
              {% end %}
              render({{status_code}}, {{render_type.id}}: result)
            end
          end
        {% end %}
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
