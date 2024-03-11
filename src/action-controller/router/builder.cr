require "../router"
require "./route_params"

# Create the method annotations
{% begin %}
  {% for http_method in ::ActionController::Router::HTTP_METHODS.reject(&.==("head")) %}
    # define a new route that responds to {{http_method.upcase}} requests
    #
    # ```crystal
    # @[AC::Route::{{http_method.upcase}}("/my/route/:name")]
    # def my_route_name(name : String) : String
    #   name
    # end
    # ```
    annotation ActionController::Route::{{http_method.upcase.id}}
    end
  {% end %}
{% end %}

# define a new route that responds to websocket requests
#
# ```
# SOCKETS = [] of HTTP::WebSocket
#
# @[AC::Route::WebSocket("/websocket/:name")]
# def websocket(socket, name : String)
#   socket.on_message do |message|
#     SOCKETS.each &.send("#{name}: #{message}")
#   end
#
#   socket.on_close do
#     SOCKETS.delete(socket)
#   end
# end
# ```
annotation ActionController::Route::WebSocket
end

# define a new route that responds to websocket requests
#
# ```
# @[AC::Route::Filter(:before_action)]
# def load_model(id : String)
#   @model = MyModel.find(id)
# end
# ```
annotation ActionController::Route::Filter
end

# define a handler for common errors
#
# ```
# @[AC::Route::Exception(AC::Route::Param::MissingError, status_code: HTTP::Status::UNPROCESSABLE_ENTITY)]
# @[AC::Route::Exception(AC::Route::Param::ValueError, status_code: HTTP::Status::BAD_REQUEST)]
# def invalid_param(error) : AC::Error::ParameterResponse
#   AC::Error::ParameterResponse.new error: error.message.as(String), parameter: error.parameter, restriction: error.restriction
# end
# ```
annotation ActionController::Route::Exception
end

# defines a custom parser for strong parameters
#
# ```
# # for converting comma seperated lists
# # i.e. `"id-1,id-2,id-3"`
# struct ConvertStringArray
#   def convert(raw : String)
#     raw.split(',').map!(&.strip).reject(&.empty?).uniq!
#   end
# end
#
# @[AC::Route::GET("/", converters: {tags: ConvertStringArray})]
# def find_tagged(tags : Array(String))
#   # ...
# end
# ```
annotation ActionController::Param::Converter
end

# See Param::Converter in the alias definition
alias ActionController::Param::Info = ActionController::Param::Converter

module ActionController::Route
  # the base class for all route related errors
  class Error < ::Exception
    def initialize(message : String? = nil, @accepts : Array(String)? = nil)
      super message
    end

    getter accepts : Array(String)?
  end

  # we don't support any of the accepted response content types
  class NotAcceptable < Error
  end

  # we don't support the posted media type
  class UnsupportedMediaType < Error
  end
end

# helpers for defining routes with strong parameters
module ActionController::Route::Builder
  # :nodoc:
  # filter name => Params used
  OPENAPI_FILTERS = {} of Nil => Nil

  # :nodoc:
  # error klass => response object name => response code
  OPENAPI_ERRORS = {} of Nil => Nil

  # :nodoc:
  # verb+route  => controller_name, route_name, params (path, query), request body schema, response object name => response code
  OPENAPI_ROUTES = {} of Nil => Nil

  # :nodoc:
  # Routing related
  ROUTE_FUNCTIONS = {} of Nil => Nil

  # by default applications respond with JSON
  DEFAULT_RESPONDER = ["application/json"]

  # :nodoc:
  RESPONDERS = {} of Nil => Nil

  # specify the responder content-type to use if the user doesn't request one
  macro default_responder(content_type)
    {% DEFAULT_RESPONDER[0] = content_type %}
    {% raise "no responder available for default content type: #{content_type}" unless RESPONDERS[content_type] %}
  end

  # add a new responder for the content-type provided, this will be called to render responses
  #
  # ```
  # add_responder("application/yaml") { |io, result| result.to_yaml(io) }
  # ```
  macro add_responder(content_type, &block)
    {% RESPONDERS[content_type] = block %}
  end

  # by default applications expect to receive JSON
  DEFAULT_PARSER = ["application/json"]

  # :nodoc:
  PARSERS = {} of Nil => Nil

  # specify the default content-type of request bodies, if the user doesn't specify one
  macro default_parser(content_type)
    {% DEFAULT_PARSER[0] = content_type %}
    {% raise "no responder available for default content type: #{content_type}" unless PARSERS[content_type] %}
  end

  # add code that can be used to deserialise request bodies of the content-type provided
  #
  # ```
  # add_parser("application/yaml") do |klass, body_io, request|
  #   request_charset = ActionController::Support.charset(request.headers)
  #   body_io.set_encoding(request_charset) if request_charset
  #   klass.from_yaml(body_io)
  # end
  # ```
  macro add_parser(content_type, &block)
    {% PARSERS[content_type] = block %}
  end

  # :nodoc:
  macro __build_transformer_functions__
      {% for type, block in RESPONDERS %}
        # :nodoc:
        def self.transform_{{type.gsub(/\W/, "_").id}}(%instance, {{block.args.splat}}, *_args)
          __yield__(%instance) do
            {{block.body}}
          end
        end
      {% end %}

      RESPONDER_LIST = [
        {% for type, _block in RESPONDERS %}
          {{type}},
        {% end %}
      ]

      # :nodoc:
      def self.can_respond_with?(content_type : Array(String)) : String?
        return DEFAULT_RESPONDER[0] if content_type.empty?
        common = content_type & RESPONDER_LIST
        return common.first if common.size > 0
        return DEFAULT_RESPONDER[0] if content_type.includes? "*/*"
        nil
      end

      # :nodoc:
      def self.accepts
        RESPONDER_LIST
      end

      {% for type, block in PARSERS %}
        # :nodoc:
        def self.parse_{{type.gsub(/\W/, "_").id}}({{block.args.splat}}, **_ignore)
          {{block.body}}
        end
      {% end %}

      PARSER_LIST = [
        {% for type, _block in PARSERS %}
          {{type}},
        {% end %}
      ]

      # :nodoc:
      def self.can_parse?(content_type)
        PARSER_LIST.includes? content_type
      end

      # :nodoc:
      def self.parsable
        PARSER_LIST
      end
  end

  # :nodoc:
  macro __parse_inferred_routes__
    # Check if they have been applied to any of the methods
    {% for method in @type.methods.sort_by(&.line_number) %}
      {% method_name = method.name %}
      {% annotation_found = false %}

      # Run through the various route annotations
      {% for route_method in {AC::Route::WebSocket, AC::Route::GET, AC::Route::POST, AC::Route::PUT, AC::Route::PATCH, AC::Route::DELETE, AC::Route::OPTIONS, AC::Route::Filter, AC::Route::Exception} %}
        {% lower_route_method = route_method.stringify.split("::")[-1].downcase.id %}

        # Multiple routes can be applied to a single method
        {% for ann, idx in method.annotations(route_method) %}
          {% annotation_found = true %}

          # OpenAPI route lookup (note full route here is not valid for exceptions and filters)
          {% full_route = (NAMESPACE[0] + ann[0].id.stringify).split("/").reject(&.empty?) %}
          {% verb_route = lower_route_method.stringify.upcase + "/" + full_route.join("/") %}

          {% if route_method == AC::Route::Filter && ann[0] == :around_action %}
            {% raise "#{@type.name}##{method_name} method must yield" unless method.accepts_block? %}
          {% else %}
            {% raise "#{@type.name}##{method_name} accepts a block, this is incompatible with the router" if method.accepts_block? %}
          {% end %}

          # Grab the response details from the annotations
          {% content_type = ann[:content_type] %}
          {% param_mapping = ann[:map] || {} of SymbolLiteral => SymbolLiteral %} # function argument name => param name
          {% status_code = ann[:status_code] || HTTP::Status::OK %}
          {% status_code_map = ann[:status] || {} of TypeNode => Path %}
          {% body_argument = (ann[:body] || "%").id.stringify %} # % is an invalid argument name

          {% open_api_route = {} of Nil => Nil %}
          {% open_api_params = {} of Nil => Nil %}

          # support annotation based filters
          {% if route_method == AC::Route::Filter %}
            {% required_params = [] of StringLiteral %}
            {% filter_type = ann[0].id %}
            {% function_wrapper_name = "_#{filter_type.stringify.underscore.gsub(/\:\:/, "_").id}_#{method_name}_wrapper_".id %}

            {% open_api_route[:request_body] = Nil %}
            {% open_api_route[:controller] = @type.name.stringify %}
            {% open_api_route[:method] = method_name.stringify %}
            {% open_api_route[:wrapper_method] = function_wrapper_name.stringify %}
            {% open_api_route[:params] = open_api_params %}
            {% OPENAPI_FILTERS[@type.name.stringify + "#" + method_name.stringify] = open_api_route %}

            {{filter_type}}({{function_wrapper_name.symbolize}}, only: {{ann[:only]}}, except: {{ann[:except]}}, filter_name: {{method_name}})

            # :nodoc:
            def {{function_wrapper_name}}
          {% elsif route_method == AC::Route::Exception %}
            # annotation based exception handlers
            {% required_params = [] of StringLiteral %}
            {% exception_class = ann[0].resolve.stringify %}
            {% function_wrapper_name = "_#{exception_class.underscore.gsub(/\:\:/, "_").id}_#{method_name}_wrapper_".id %}

            {% open_api_route[:controller] = @type.name.stringify %}
            {% open_api_route[:exception] = exception_class %}
            {% open_api_route[:responses] = {} of Nil => Nil %}
            {% open_api_route[:method] = method_name.stringify %}
            {% OPENAPI_ERRORS[@type.name.stringify + "#" + exception_class] = open_api_route %}

            rescue_from {{exception_class.id}}, {{function_wrapper_name.symbolize}}

            # :nodoc:
            def {{function_wrapper_name}}(error : {{exception_class.id}})
              # Check we can satisfy the accepts header, if provided
              {% if content_type %}
                responds_with = {{content_type}}
              {% else %}
                responds_with = {{@type.name.id}}.can_respond_with?(accepts_formats) || DEFAULT_RESPONDER[0]
              {% end %}
          {% else %}
            # annotation based route

            # Grab the param parts
            {% required_params = full_route.select(&.starts_with?(":")).map { |part| part.split(":")[1] } %}
            {% optional_params = full_route.select(&.starts_with?("?:")).map { |part| part.split(":")[1] } %}
            # {% splat_params = full_route.select(&.starts_with?("*:")).map { |part| part.split(":")[1] } %}

            {% open_api_route[:request_body] = Nil %}
            {% open_api_route[:controller] = @type.name.stringify %}
            {% open_api_route[:responses] = {} of Nil => Nil %}
            {% open_api_route[:method] = method_name.stringify %}
            {% open_api_route[:route] = "/" + full_route.join("/") %}
            {% open_api_route[:verb] = lower_route_method.stringify %}
            {% OPENAPI_ROUTES[verb_route] = open_api_route %}

            # initial recording of path params
            {% for path_param in required_params %}
              {% open_api_params[path_param] = {} of Nil => Nil %}
              {% open_api_params[path_param][:in] = :path %}
              {% open_api_params[path_param][:required] = true %}
              {% open_api_params[path_param][:schema] = Nil %}
            {% end %}
            {% for path_param in optional_params %}
              {% open_api_params[path_param] = {} of Nil => Nil %}
              {% open_api_params[path_param][:in] = :path %}
              {% open_api_params[path_param][:required] = false %}
              {% open_api_params[path_param][:schema] = Nil %}
            {% end %}
            {% open_api_route[:params] = open_api_params %}

            # add a redirect helper (yes, it will only match the last route applied)
            {% if lower_route_method.stringify == "get" %}
              def self.{{method_name.id}}(**tuple_parts)
                route = {{"/" + full_route.join("/")}}
                ActionController::Support.build_route(route, nil, **tuple_parts)
              end
            {% end %}

            # :nodoc:
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
                  responds_with = {{@type.name.id}}.can_respond_with?(accepts_formats)
                  raise AC::Route::NotAcceptable.new("no renderer available for #{accepts_formats.join(" or ")}, accepts #{RESPONDER_LIST.join(" or ")}", {{@type.name.id}}.accepts) unless responds_with
                {% end %}
            {% end %}
          {% end %}
            # grab any custom converters or customisations
            {% converters = ann[:converters] || {} of SymbolLiteral => NilLiteral %}
            {% config = ann[:config] || {} of SymbolLiteral => NilLiteral %}

            # Write the method body
            {% if method.args.empty? || ({AC::Route::Exception, AC::Route::WebSocket}.includes?(route_method) && method.args.size == 1) %}
              {% if route_method == AC::Route::WebSocket %}
                {{method_name.id}}(socket)
              {% elsif route_method == AC::Route::Exception %}
                result = {{method_name.id}}(error)
              {% else %}
                result = {{method_name.id}} {% if route_method == AC::Route::Filter && ann[0] == :around_action %} { yield } {% end %}
              {% end %}
            {% else %}
              # check we can parse the body if a content type is provided
              {% if body_argument != "%" %}
                body_type = request_content_type || {{ DEFAULT_PARSER[0] }}
                unless {{@type.name.id}}.can_parse?(body_type)
                  raise AC::Route::UnsupportedMediaType.new("no parser available for #{body_type}", {{@type.name.id}}.parsable)
                end
              {% end %}

              args = {
                {% for arg, arg_index in method.args %}
                  {% unless arg_index == 0 && {AC::Route::Exception, AC::Route::WebSocket}.includes?(route_method) %}
                    # Check for converters, route level config takes precedence over param level
                    {% ann_converter = arg.annotation(::ActionController::Param::Converter) %}
                    {% string_name = arg.name.id.stringify %}
                    {% query_param_name = (param_mapping[string_name.id.symbolize] || (ann_converter && ann_converter[:name]) || string_name).id.stringify %}

                    {% custom_converter = converters[string_name.id.symbolize] || (ann_converter && ann_converter[:class]) %}
                    {% converter_args = config[string_name.id.symbolize] || (ann_converter && ann_converter[:config]) %}

                    {% if body_argument == string_name %}
                      {% open_api_param = {} of Nil => Nil %}
                    {% else %}
                      {% open_api_param = open_api_params[query_param_name] || {} of Nil => Nil %}
                      {% open_api_param[:in] = open_api_param[:in] || :query %}
                      {% open_api_param[:docs] = (ann_converter && ann_converter[:description]) %}
                      {% open_api_param[:example] = (ann_converter && ann_converter[:example]) %}
                      {% open_api_params[query_param_name] = open_api_param %}
                    {% end %}

                    # Calculate the conversions required to meet the desired restrictions
                    {% if arg.restriction %}
                      {% open_api_param[:schema] = arg.restriction.resolve %}

                      # Check if restriction is optional
                      {% nilable = arg.restriction.resolve.nilable? %}

                      # Check if there are any custom converters
                      {% if custom_converter %}
                        {% if converter_args %}
                          {% restrictions = [custom_converter.stringify + ".new(**" + converter_args.stringify + ").convert(param_value)"] %}
                        {% else %}
                          {% restrictions = [custom_converter.stringify + ".new.convert(param_value)"] %}
                        {% end %}

                      # Check for custom converter arguments (assumes a single type)
                      {% elsif converter_args %}
                        {% union_types = arg.restriction.resolve.union_types.reject(&.nilable?) %}
                        {% if union_types[0] < Enum %}
                          {% if converter_args[:from_value] %}
                            {% restrictions = [union_types[0].stringify + ".from_value?(param_value.to_i64)"] %}
                          {% else %}
                            {% restrictions = ["::AC::Route::Param::ConvertEnum(" + union_types[0].stringify + ").convert(param_value)"] %}
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
                        {% restrictions = union_types.map do |type|
                             if type.resolve < Enum
                               ("::AC::Route::Param::ConvertEnum(" + type.stringify + ").convert(param_value)")
                             else
                               ("::AC::Route::Param::Convert" + type.stringify + ".new.convert(param_value)")
                             end
                           end %}
                      {% end %}
                    {% else %}
                      {% nilable = true %}
                      {% restrictions = ["::AC::Route::Param::ConvertString.new.convert(param_value)"] %}

                      {% open_api_param[:schema] = "String?".id %}
                    {% end %}

                    {% open_api_param[:required] = open_api_param[:required] || (!nilable && arg.default_value.stringify == "") %}

                    # Build the argument named tuple with the correct types
                    {{arg.name.id}}: (
                      {% if body_argument == string_name %}
                        {% open_api_route[:request_body] = arg.restriction.resolve %}

                        if body_io = @__context__.request.body
                          case body_type
                          {% for type, _block in PARSERS %}
                            when {{type}}
                              {{@type.name.id}}.parse_{{type.gsub(/\W/, "_").id}}({{ arg.restriction }}, body_io, request: @__context__.request)
                          {% end %}
                          end
                        {% if arg.default_value.stringify != "" %}
                        else
                          {{arg.default_value}}
                        {% end %}
                        end

                      # Required route param, so we ensure it
                      {% elsif required_params.includes? string_name %}
                        if param_value = route_params[{{query_param_name}}]?
                          {{restrictions.join(" || ").id}}
                        else
                          raise ::AC::Route::Param::MissingError.new("missing required parameter", {{query_param_name}}, {{arg.restriction.resolve.stringify}})
                        end

                      # An optional route param, might be passed as an query param
                      {% else %}
                        if param_value = params[{{query_param_name}}]?
                          {{restrictions.join(" || ").id}}
                        {% if arg.default_value.stringify != "" %}
                        else
                          {{arg.default_value}}
                        {% end %}
                        end
                      {% end %}

                    # Use tap to ensure a good error message if the function param isn't nilable
                    ){% if !nilable %}.tap { |result|
                      if result.nil?
                        if params.has_key?({{query_param_name}})
                          raise ::AC::Route::Param::ValueError.new("invalid parameter value", {{query_param_name}}, {{arg.restriction.resolve.stringify}})
                        else
                          raise ::AC::Route::Param::MissingError.new("missing required parameter", {{query_param_name}}, {{arg.restriction.resolve.stringify}})
                        end
                      end
                    }.not_nil!{% end %},
                  {% end %}
                {% end %}
              }

              {% if route_method == AC::Route::WebSocket %}
                {{method_name.id}}(socket, **args)
              {% elsif route_method == AC::Route::Exception %}
                result = {{method_name.id}}(error, **args)
              {% else %}
                result = {{method_name.id}}(**args){% if route_method == AC::Route::Filter && ann[0] == :around_action %} { yield } {% end %}
              {% end %}
            {% end %}

            {% if route_method == AC::Route::WebSocket %}
              {% open_api_route[:default_response] = {Nil, 101, false} %}
            {% end %}

            {% if !{AC::Route::Filter, AC::Route::WebSocket}.includes?(route_method) %}
              {% if method.return_type %}
                {% open_api_route[:default_response] = {method.return_type.resolve, status_code, true} %}
              {% else %}
                {% open_api_route[:default_response] = {Nil, status_code, false} %}
              {% end %}

              unless @__render_called__
                responose = @__context__.response
                {% if status_code_map.empty? %}
                  response.status_code = ({{status_code}}).to_i
                {% else %}
                  case result
                    {% for result_klass, status_mapped in status_code_map %}
                  when {{result_klass}}
                      {% open_api_route[:responses][result_klass] = status_mapped %}
                      response.status_code = ({{status_mapped}}).to_i
                    {% end %}
                  else
                    response.status_code = ({{status_code}}).to_i
                  end
                {% end %}
                content_type = response.headers["Content-Type"]?
                response.headers["Content-Type"] = responds_with unless content_type

                session = @__session__
                session.encode(response.cookies) if session && session.modified?

                unless @__head_request__ || result.nil?
                  case responds_with
                  {% for type, _block in RESPONDERS %}
                    when {{type}}
                      {{@type.name.id}}.transform_{{type.gsub(/\W/, "_").id}}(self, response, result, {{@type.name.underscore.symbolize}}, {{method_name.id.symbolize}})
                  {% end %}
                  else
                    # return the default, which is allowed in HTTP 1.1
                    # we've checked the accepts header at the top of the function and this might be an error response
                    {{@type.name.id}}.transform_{{DEFAULT_RESPONDER[0].gsub(/\W/, "_").id}}(self, response, result, {{@type.name.underscore.symbolize}}, {{method_name.id.symbolize}})
                  end
                end
                @__render_called__ = true
              end
            {% end %}
          end
        {% end %}
      {% end %}

      {% if annotation_found %}
        # ensure this method hasn't already been used (overloading is undesirable)
        {% klasses = [@type.name.id] %}
        {% @type.ancestors.each { |name| klasses.unshift(name) } %}

        {% for klass in klasses %}
          {% if ROUTE_FUNCTIONS["#{klass}##{method_name}"] %}
            {% raise "#{@type.name.id}##{method_name} already exists in #{klass}, duplicate annotated function names are not allowed" %}
          {% end %}
        {% end %}

        {% ROUTE_FUNCTIONS["#{@type.name.id}##{method_name}"] = true %}
      {% end %}
    {% end %}
	end

  macro included
    # JSON APIs by default

    # Responders are executed in the context of the controller so can access all controller instance methods
    add_responder("application/json") { |io, result| result.to_json(io) }
    default_responder "application/json"

    # parsers have access to the request so they can modify how they parse the body
    # for example there might be a difference between PUT and PATCH semantics
    add_parser("application/json") do |klass, body_io, request|
      request_charset = ActionController::Support.charset(request.headers)
      body_io.set_encoding(request_charset) if request_charset
      klass.from_json(body_io)
    end
    default_parser "application/json"

    macro inherited
      macro finished
        __build_transformer_functions__
        __parse_inferred_routes__
      end
    end
  end
end
