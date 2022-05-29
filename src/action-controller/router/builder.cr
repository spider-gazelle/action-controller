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

module ActionController::Route
  class Error < ::Exception
  end

  # we don't support any of the accepted response content types
  class NotAcceptable < Error
    def initialize(message : String? = nil, @accepts : Array(String)? = nil)
      super message
    end

    getter accepts : Array(String)?
  end

  # we don't support the posted media type
  class UnsupportedMediaType < NotAcceptable
  end
end

module ActionController::Route::Builder
  DEFAULT_RESPONDER = ["application/json"]
  RESPONDERS        = {} of Nil => Nil

  macro default_responder(content_type)
    {% DEFAULT_RESPONDER[0] = content_type %}
    {% raise "no responder available for default content type: #{content_type}" unless RESPONDERS[content_type] %}
  end

  macro add_responder(content_type, &block)
    {% RESPONDERS[content_type] = block %}
  end

  DEFAULT_PARSER = ["application/json"]
  PARSERS        = {} of Nil => Nil

  macro default_parser(content_type)
    {% DEFAULT_PARSER[0] = content_type %}
    {% raise "no responder available for default content type: #{content_type}" unless PARSERS[content_type] %}
  end

  macro add_parser(content_type, &block)
    {% PARSERS[content_type] = block %}
  end

  macro __build_transformer_functions__
    # :nodoc:
    module {{@type.name.id}}Transformers
      {% for type, block in RESPONDERS %}
        # :nodoc:
        def self.{{type.gsub(/\/|\-|\~|\*|\:|\./, "_").id}}({{*block.args}})
          {{block.body}}
        end
      {% end %}

      RESPONDERS = [
        {% for type, _block in RESPONDERS %}
          {{type}},
        {% end %}
      ]

      # :nodoc:
      def self.can_respond_with?(content_type)
        RESPONDERS.includes? content_type
      end

      # :nodoc:
      def self.accepts
        RESPONDERS
      end

      {% for type, block in PARSERS %}
        # :nodoc:
        def self.parse_{{type.gsub(/\/|\-|\~|\*|\:|\./, "_").id}}({{*block.args}})
          {{block.body}}
        end
      {% end %}

      PARSERS = [
        {% for type, _block in PARSERS %}
          {{type}},
        {% end %}
      ]

      # :nodoc:
      def self.can_parse?(content_type)
        PARSERS.includes? content_type
      end

      # :nodoc:
      def self.parsable
        PARSERS
      end
    end
  end

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
          {% body_argument = (ann[:body] || "%").id.stringify %} # % is an invalid argument name

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
              # Check we can satisfy the accepts header, if provided
              {% if content_type %}
                responds_with = {{content_type}}
              {% else %}
                responds_with = accepts_formats.first? || {{ DEFAULT_RESPONDER[0] }}
                responds_with = {{ DEFAULT_RESPONDER[0] }} unless {{@type.name.id}}Transformers.can_respond_with?(responds_with)
              {% end %}
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

                # Check we can satisfy the accepts header, if provided
                {% if content_type %}
                  responds_with = {{content_type}}
                {% else %}
                  responds_with = accepts_formats.first? || {{ DEFAULT_RESPONDER[0] }}
                  raise AC::Route::NotAcceptable.new("no renderer available for #{responds_with}", {{@type.name.id}}Transformers.accepts) unless {{@type.name.id}}Transformers.can_respond_with?(responds_with)
                {% end %}
            {% end %}
          {% end %}
            # grab any custom converters or customisations
            {% converters = ann[:converters] || {} of SymbolLiteral => NilLiteral %}
            {% config = ann[:config] || {} of SymbolLiteral => NilLiteral %}

            # Write the method body
            {% if method.args.empty? %}
              result = {{method_name.id}}
            {% else %}
              # check we can parse the body if a content type is provided
              {% if body_argument != "%" %}
                body_type = @context.request.headers["Content-Type"]? || {{ DEFAULT_PARSER[0] }}
                unless {{@type.name.id}}Transformers.can_parse?(body_type)
                  raise AC::Route::UnsupportedMediaType.new("no parser available for #{body_type}", {{@type.name.id}}Transformers.parsable)
                end
              {% end %}

              args = {
                {% for arg, arg_index in method.args %}
                  {% unless arg_index == 0 && {AC::Route::Exception, AC::Route::WebSocket}.includes?(route_method) %}
                    {% string_name = arg.name.id.stringify %}

                    # Calculate the conversions required to meet the desired restrictions
                    {% if arg.restriction %}
                      # Check if restriction is optional
                      {% nilable = arg.restriction.resolve.nilable? %}

                      # Check if there are any custom converters
                      {% if custom_converter = converters[string_name.id.symbolize] %}
                        {% if converter_args = config[string_name.id.symbolize] %}
                          {% restrictions = [custom_converter.stringify + ".new(**" + converter_args.stringify + ").convert(param_value)"] %}
                        {% else %}
                          {% restrictions = [custom_converter.stringify + ".new.convert(param_value)"] %}
                        {% end %}

                      # Check for custom converter arguments (assumes a single type)
                      {% elsif converter_args = config[string_name.id.symbolize] %}
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

                      # do we want to parse the request body
                      {% elsif body_argument == string_name %}
                        # ignore this arg here

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
                      {% if body_argument == string_name %}
                        if body_io = @context.request.body
                          case body_type
                          {% for type, _block in PARSERS %}
                            when {{type}}
                              {{@type.name.id}}Transformers.parse_{{type.gsub(/\/|\-|\~|\*|\:|\./, "_").id}}({{ arg.restriction }}, body_io)
                          {% end %}
                          end
                        end

                      # Required route param, so we ensure it
                      {% elsif required_params.includes? string_name %}
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
                responose = @context.response
                response.status_code = ({{status_code}}).to_i
                content_type = response.headers["Content-Type"]?
                response.headers["Content-Type"] = responds_with unless content_type

                session = @__session__
                session.encode(response.cookies) if session && session.modified

                unless @__head_request__
                  case responds_with
                  {% for type, _block in RESPONDERS %}
                    when {{type}}
                      {{@type.name.id}}Transformers.{{type.gsub(/\/|\-|\~|\*|\:|\./, "_").id}}(response, result)
                  {% end %}
                  else
                    # return the default, which is allowed in HTTP 1.1
                    # we've checked the accepts header at the top of the function and this might be an error response
                    {{@type.name.id}}Transformers.{{DEFAULT_RESPONDER[0].gsub(/\/|\-|\~|\*|\:|\./, "_").id}}(response, result)
                  end
                end
                @render_called = true
              end
            {% end %}
          end
        {% end %}
      {% end %}
    {% end %}
	end

  macro included
    add_responder("application/json") { |io, result| result.to_json(io) }
    add_responder("application/yaml") { |io, result| result.to_yaml(io) }
    default_responder "application/json"

    add_parser("application/json") { |klass, body_io| klass.from_json(body_io.gets_to_end) }
    add_parser("application/yaml") { |klass, body_io| klass.from_yaml(body_io.gets_to_end) }
    default_parser "application/json"

    macro inherited
      macro finished
        __build_transformer_functions__
        __parse_inferred_routes__
      end
    end
	end
end
