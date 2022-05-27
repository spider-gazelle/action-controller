require "../router"
require "./route_params"

# Create the method annotations
{% begin %}
  {% for http_method in ::ActionController::Router::HTTP_METHODS.reject(&.==("head")) %}
    annotation ActionController::Route::{{http_method.upcase.id}}
    end
  {% end %}
{% end %}

annotation ActionController::Route::WebSocket
end

annotation ActionController::Route::Filter
end

annotation ActionController::Route::Exception
end

module ActionController::Route::Builder
  macro __parse_inferred_routes__
    # Run through the various route annotations
    {% for route_method in {AC::Route::WebSocket, AC::Route::GET, AC::Route::POST, AC::Route::PUT, AC::Route::PATCH, AC::Route::DELETE, AC::Route::OPTIONS, AC::Route::Filter, AC::Route::Exception} %}
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

          # support annotation based filters
          {% if route_method == AC::Route::Filter %}
            {% required_params = [] of StringLiteral %}
            {% filter_type = ann[0].id %}
            {% function_wrapper_name = "_#{filter_type}_#{method_name}_wrapper_".id %}

            {{filter_type}}({{function_wrapper_name.symbolize}}, only: {{ann[:only]}}, except: {{ann[:except]}})

            # :nodoc:
            def {{function_wrapper_name}}
          {% elsif route_method == AC::Route::Exception %}
            # annotation based exception handlers
            {% required_params = [] of StringLiteral %}
            {% exception_class = ann[0] %}
            {% function_wrapper_name = "_#{exception_class.stringify.downcase.id}_#{method_name}_wrapper_".id %}

            rescue_from DivisionByZeroError, {{function_wrapper_name.symbolize}}

            # :nodoc:
            def {{function_wrapper_name}}(error)
          {% else %}
            # annotation based route

            # Grab the param parts
            {% full_route = (NAMESPACE[0] + ann[0]).split("/").reject(&.empty?) %}
            {% required_params = full_route.select(&.starts_with?(":")).map { |part| part.split(":")[1] } %}
            # {% optional_params = full_route.select(&.starts_with?("?:")).map { |part| part.split(":")[1] } %}
            # {% splat_params = full_route.select(&.starts_with?("*:")).map { |part| part.split(":")[1] } %}

            # add a redirect helper (yes, it will only match the last route applied)
            {% if lower_route_method == "get" %}
              def self.{{method_name.id}}(**tuple_parts)
                route = {{"/" + full_route.join("/")}}
                ActionController::Support.build_route(route, nil, **tuple_parts)
              end
            {% end %}

            # build the standard route definition helper (get "/route")
            {% if route_method == AC::Route::WebSocket %}
              # :nodoc:
              ws {{ann[0]}}, reference: {{method_name}} do |socket|
            {% else %}
              # :nodoc:
              {{lower_route_method}} {{ann[0]}}, reference: {{method_name}} do
            {% end %}
          {% end %}

            # Write the method body
            {% if method.args.empty? %}
              result = {{method_name.id}}
            {% else %}
              args = {
                {% for arg, arg_index in method.args %}
                  {% unless arg_index == 0 && {AC::Route::Exception, AC::Route::WebSocket}.includes?(route_method) %}
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
                        {% if union_types[0] < Enum %}
                          {% if converter_args[:from_value] %}
                            {% restrictions = [union_types[0].stringify + ".from_value?(param_value.to_i64)"] %}
                          {% else %}
                            {% restrictions = [union_types[0].stringify + ".parse?(param_value)"] %}
                          {% end %}
                        {% else %}
                          {% restrictions = ["::AC::Route::Param::Convert" + union_types[0].stringify + ".new(**" + converter_args.stringify + ").convert(param_value)"] %}
                        {% end %}

                      # There are a bunch of types this might be
                      {% else %}
                        {% union_types = arg.restriction.resolve.union_types.reject(&.nilable?) %}
                        {% if union_types[0] < Enum %}
                          {% restrictions = [union_types[0].stringify + ".parse?(param_value)"] %}
                        {% else %}
                          {% restrictions = union_types.map { |type| "::AC::Route::Param::Convert" + type.stringify + ".new.convert(param_value)" } %}
                        {% end %}
                      {% end %}
                    {% else %}
                      {% nilable = true %}
                      {% restrictions = ["::AC::Route::Param::ConvertString.new.convert(param_value)"] %}
                    {% end %}

                    # Build the argument named tuple with the correct types
                    {{arg.name.id}}: (

                      # Required route param, so we ensure it
                      {% if required_params.includes? string_name %}
                        if param_value = route_params[{{string_name}}]?
                          {{restrictions.join(" || ").id}}
                        else
                          raise ::AC::Route::Param::MissingError.new("missing required parameter", {{string_name}}, {{arg.restriction.resolve.stringify}})
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
                    ){% if !nilable %}.tap { |result| raise AC::Route::Param::ValueError.new("invalid parameter value", {{string_name}}, {{arg.restriction.resolve.stringify}}) if result.nil? }.not_nil!{% end %},
                  {% end %}
                {% end %}
              }

              {% if route_method == AC::Route::WebSocket %}
                {{method_name.id}}(socket, **args)
              {% elsif route_method == AC::Route::Exception %}
                result = {{method_name.id}}(error, **args)
              {% else %}
                result = {{method_name.id}}(**args)
              {% end %}
            {% end %}

            {% if !{AC::Route::Filter, AC::Route::WebSocket}.includes?(route_method) %}
              unless @render_called
                {% if content_type %}
                  @context.response.headers["Content-Type"] = {{content_type}}
                {% end %}
                render({{status_code}}, {{render_type.id}}: result)
              end
            {% end %}
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
