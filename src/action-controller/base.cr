require "openssl/sha1"
require "./responders"
require "./session"
require "./support"

abstract class ActionController::Base
  include ActionController::Responders

  Habitat.create do
    setting logger : Logger = Logger.new(STDOUT)
  end

  # Base route => klass name
  CONCRETE_CONTROLLERS = {} of Nil => Nil
  FILTER_TYPES         = %w(ROUTES BEFORE AROUND AFTER RESCUE FORCE)

  {% for ftype in FILTER_TYPES %}
    # klass => {function => options}
    {{ftype.id}}_MAPPINGS = {} of Nil => Nil
  {% end %}

  macro __build_filter_inheritance_macros__
    {% for ftype in FILTER_TYPES %}
      {% ltype = ftype.downcase %}

      macro __inherit_{{ltype.id}}_filters__
        \{% {{ftype.id}}_MAPPINGS[@type.name.id] = LOCAL_{{ftype.id}} %}
        \{% klasses = [@type.name.id] + @type.ancestors %}

        # Create a mapping of all field names and types
        \{% for name in klasses %}
          \{% filters = {{ftype.id}}_MAPPINGS[name.id] %}

          \{% if filters && !filters.empty? %}
            \{% for name, options in filters %}
              \{% if !{{ftype.id}}[name] %}
                \{% {{ftype.id}}[name] = options %}
              \{% end %}
            \{% end %}
          \{% end %}
        \{% end %}
      end
    {% end %}
  end

  CRUD_METHODS = {
    "index"   => {"get", "/"},
    "show"    => {"get", "/:id"},
    "create"  => {"post", "/"},
    "update"  => {"patch", "/:id"},
    "replace" => {"put", "/:id"},
    "destroy" => {"delete", "/:id"},
  }

  getter logger : Logger
  getter render_called
  getter action_name : Symbol
  getter params : HTTP::Params
  getter cookies : HTTP::Cookies
  getter request : HTTP::Request
  getter response : HTTP::Server::Response
  getter __session__ : Session | Nil

  def initialize(context : HTTP::Server::Context, params = {} of String => String, @action_name = :index)
    # Default params are provided to simplify testing

    @render_called = false
    @request = context.request
    @response = context.response
    @cookies = @request.cookies
    @params = @request.query_params

    @logger = settings.logger

    # Add route params to the HTTP params
    # giving preference to route params
    params.each do |key, value|
      values = @params.fetch_all(key) || [] of String
      values.unshift(value)
      @params.set_all(key, values)
    end
  end

  def session
    @__session__ ||= Session.from_cookies(@cookies)
  end

  macro inherited
    # default namespace based on class
    NAMESPACE = [{{"/" + @type.name.stringify.underscore.gsub(/\:\:/, "/")}}]

    {% for ftype in FILTER_TYPES %}
      # function => options
      LOCAL_{{ftype.id}} = {} of Nil => Nil
      {{ftype.id}} = {} of Nil => Nil
    {% end %}

    __build_filter_inheritance_macros__

    macro finished
      __build_filter_mappings__
      __create_route_methods__

      # Create draw_routes function
      #
      # Create instance of controller class init with context, params and logger
      # protocol checks (https etc)
      # controller instance created
      # begin exception helpers
      # inline the around filters
      # inline the before filters
      # inline the action
      # inline the after filters
      # rescue exception handlers
      __draw_routes__
    end
  end

  macro __build_filter_mappings__
    {% for ftype in FILTER_TYPES %}
      {% ltype = ftype.downcase %}
      __inherit_{{ltype.id}}_filters__
    {% end %}
  end

  macro __create_route_methods__
    {% if !@type.abstract? %}
      # Add CRUD routes to the map
      {% for name, index in @type.methods.map(&.name.stringify) %}
        {% args = CRUD_METHODS[name] %}
        {% if args %}
          {% ROUTES[name.id] = {args[0], args[1], nil, false} %}
        {% end %}
      {% end %}

      # Create functions for named routes
      {% for name, details in ROUTES %}
        {% block = details[2] %}
        {% if block != nil %} # Skip the CRUD
          def {{name}}({{*block.args}})
            {{block.body}}
          end
        {% end %}
      {% end %}

      # Create functions as required for errors
      {% for klass, details in RESCUE %}
        {% block = details[1] %}
        {% if block != nil %} # Skip the CRUD
          def {{details[0]}}({{*details[1].args}})
            {{details[1].body}}
          end
        {% end %}
      {% end %}
    {% end %}
  end

  # To support inheritance
  def self.__init_routes__(router)
    nil
  end

  def self.__route_list__
    # Class, name, verb, route
    [] of {String, Symbol, Symbol, String}
  end

  def self.__yield__(inst)
    with inst yield
  end

  macro __draw_routes__
    {% if !@type.abstract? && !ROUTES.empty? %}
      {% CONCRETE_CONTROLLERS[@type.name.id] = NAMESPACE[0] %}

      def self.__init_routes__(router)
        {% for name, details in ROUTES %}
          router.{{details[0].id}} "{{NAMESPACE[0].id}}{{details[1].id}}".gsub("//", "/") do |context, params|
            {% is_websocket = details[3] %}

            # Check if force SSL is set and redirect to HTTPS if HTTP
            {% force = false %}
            {% if FORCE[:force] %}
              {% options = FORCE[:force] %}
              {% only = options[0] %}
              {% if only != nil && only.includes?(name) %} # only
                {% force = true %}
              {% else %}
                {% except = options[1] %}
                {% if except != nil && !except.includes?(name) %} # except
                  {% force = true %}
                {% end %}
              {% end %}
            {% end %}
            {% if force %}
              if ActionController::Support.request_protocol(context.request) != :https
              {% if is_websocket %}
                response = context.response
                response.status_code = {{STATUS_CODES[:precondition_failed]}}
                response.content_type = MIME_TYPES[:text]
                response.print "WebSocket Secure (wss://) connection required"
              {% else %}
                ActionController::Support.redirect_to_https(context)
              {% end %}
              else
            {% end %}

            # Create an instance of the controller
            instance = {{@type.name}}.new(context, params, :{{name}})

            # Check for errors
            {% if !RESCUE.empty? %}
              begin
            {% end %}

            # Execute the around filters
            {% around_actions = AROUND.keys %}
            {% for method, options in AROUND %}
              {% only = options[0] %}
              {% if only != nil && !only.includes?(name) %} # only
                {% around_actions = around_actions.reject { |act| act == method } %}
              {% else %}
                {% except = options[1] %}
                {% if except != nil && except.includes?(name) %} # except
                  {% around_actions = around_actions.reject { |act| act == method } %}
                {% end %}
              {% end %}
            {% end %}
            {% if !around_actions.empty? %}
              ActionController::Base.__yield__(instance) do
                {% for action in around_actions %}
                    {{action}} do
                {% end %}
            {% end %}

            # Execute the before filters
            {% before_actions = BEFORE.keys %}
            {% for method, options in BEFORE %}
              {% only = options[0] %}
              {% if only != nil && !only.includes?(name) %} # only
                {% before_actions = before_actions.reject { |act| act == method } %}
              {% else %}
                {% except = options[1] %}
                {% if except != nil && except.includes?(name) %} # except
                  {% before_actions = before_actions.reject { |act| act == method } %}
                {% end %}
              {% end %}
            {% end %}
            {% if !before_actions.empty? %}
              {% if around_actions.empty? %}
                ActionController::Base.__yield__(instance) do
              {% end %}
                {% for action in before_actions %}
                  {{action}} unless render_called
                {% end %}
              {% if around_actions.empty? %}
                end
              {% end %}
            {% end %}

            # Check if render could have been before performing the action
            {% if !before_actions.empty? %}
              if !instance.render_called
            {% end %}

              # Call the action
              {% if is_websocket %}
                # Based on code from https://github.com/crystal-lang/crystal/blob/master/src/http/server/handlers/websocket_handler.cr
                if ActionController::Support.websocket_upgrade_request?(context.request)
                  key = context.request.headers["Sec-Websocket-Key"]

                  accept_code = Base64.strict_encode(OpenSSL::SHA1.hash("#{key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

                  response = context.response
                  response.status_code = 101
                  response.headers["Upgrade"] = "websocket"
                  response.headers["Connection"] = "Upgrade"
                  response.headers["Sec-Websocket-Accept"] = accept_code
                  response.upgrade do |io|
                    begin
                      ws_session = HTTP::WebSocket.new(io)
                      instance.{{name}}(ws_session)
                      ws_session.run
                    ensure
                      io.close
                    end
                  end
                else
                  response = context.response
                  response.status_code = {{STATUS_CODES[:upgrade_required]}}
                  response.content_type = MIME_TYPES[:text]
                  response.print "This service requires use of the WebSocket protocol"
                end
              {% else %}
                instance.{{name}}
              {% end %}

            {% if !before_actions.empty? %}
              end # END before action render_called check
            {% end %}

            # END around action blocks
            {% if !around_actions.empty? %}
              {% for action in around_actions %}
                nil
                end
              {% end %}
              end
            {% end %}

            # Execute the after filters
            {% after_actions = AFTER.keys %}
            {% for method, options in AFTER %}
              {% only = options[0] %}
              {% if only != nil && !only.includes?(name) %} # only
                {% after_actions = after_actions.reject { |act| act == method } %}
              {% else %}
                {% except = options[1] %}
                {% if except != nil && except.includes?(name) %} # except
                  {% after_actions = after_actions.reject { |act| act == method } %}
                {% end %}
              {% end %}
            {% end %}
            {% if !after_actions.empty? %}
              ActionController::Base.__yield__(instance) do
                {% for action in after_actions %}
                  {{action}}
                {% end %}
              end
            {% end %}

            # Check if session needs to be written
            session = instance.__session__
            if session && session.modified
              session.encode(context.response.cookies)
            end

            # Implement error handling
            {% if !RESCUE.empty? %}
              {% for exception, details in RESCUE %}
                rescue e : {{exception.id}}
                  if !instance.render_called
                    instance.{{details[0]}}(e)
                  else
                    raise e
                  end
              {% end %}

              end
            {% end %}

            {% if force %}
              end # END force SSL check
            {% end %}

            # Always return the context
            context
          end
        {% end %}

        nil
      end

      # Helper methods for performing redirect_to calls
      {% for name, details in ROUTES %}
        def self.{{name}}(hash_parts = {} of (String | Symbol) => (Nil | Bool | Int32 | Int64 | Float32 | Float64 | String | Symbol), **tuple_parts)
          route = "{{NAMESPACE[0].id}}{{details[1].id}}".gsub("//", "/")
          hash_parts.each do |key, value|
            route = route.gsub(":#{key}", value.to_s)
          end

          # Tuple overwrites hash parts (so safe to use a user generated hash)
          tuple_parts.each do |key, value|
            route = route.gsub(":#{key}", value.to_s)
          end
          route
        end
      {% end %}

      def self.__route_list__
        [
          # "Class", :name, :verb, "route"
          {% for name, details in ROUTES %}
            { "{{@type.name}}", :{{name}}, :{{details[0].id}}, "{{NAMESPACE[0].id}}{{details[1].id}}".gsub("//", "/")},
          {% end %}
        ]
      end
    {% end %}
  end

  macro base(name = nil)
    {% if name.nil? || name.empty? || name == "/" %}
      {% NAMESPACE[0] = "/" %}
    {% else %}
      {% if name.id.stringify.starts_with?("/") %}
        {% NAMESPACE[0] = name.id.stringify %}
      {% else %}
        {% NAMESPACE[0] = "/" + name.id.stringify %}
      {% end %}
    {% end %}
  end

  # Define each method for supported http methods
  {% for http_method in ::Router::HTTP_METHODS %}
    macro {{http_method.id}}(path, name, &block)
      \{% LOCAL_ROUTES[name.id] = { {{http_method}}, path, block, false } %}
    end
  {% end %}

  macro ws(path, name, &block)
    {% LOCAL_ROUTES[name.id] = {"get", path, block, true} %}
  end

  macro rescue_from(error_class, method = nil, &block)
    {% if method %}
      {% LOCAL_RESCUE[error_class] = {method.id, nil} %}
    {% else %}
      {% method = error_class.stringify.underscore.gsub(/\:\:/, "_") %}
      {% LOCAL_RESCUE[error_class] = {method.id, block} %}
    {% end %}
  end

  macro around_action(method, only = nil, except = nil)
    {% if only %}
      {% if !only.is_a?(ArrayLiteral) %}
        {% only = [only.id] %}
      {% else %}
        {% only = only.map(&.id) %}
      {% end %}
    {% end %}
    {% if except %}
      {% if !except.is_a?(ArrayLiteral) %}
        {% except = [except.id] %}
      {% else %}
        {% except = except.map(&.id) %}
      {% end %}
    {% end %}
    {% LOCAL_AROUND[method.id] = {only, except} %}
  end

  macro before_action(method, only = nil, except = nil)
    {% if only %}
      {% if !only.is_a?(ArrayLiteral) %}
        {% only = [only.id] %}
      {% else %}
        {% only = only.map(&.id) %}
      {% end %}
    {% end %}
    {% if except %}
      {% if !except.is_a?(ArrayLiteral) %}
        {% except = [except.id] %}
      {% else %}
        {% except = except.map(&.id) %}
      {% end %}
    {% end %}
    {% LOCAL_BEFORE[method.id] = {only, except} %}
  end

  macro after_action(method, only = nil, except = nil)
    {% if only %}
      {% if !only.is_a?(ArrayLiteral) %}
        {% only = [only.id] %}
      {% else %}
        {% only = only.map(&.id) %}
      {% end %}
    {% end %}
    {% if except %}
      {% if !except.is_a?(ArrayLiteral) %}
        {% except = [except.id] %}
      {% else %}
        {% except = except.map(&.id) %}
      {% end %}
    {% end %}
    {% LOCAL_AFTER[method.id] = {only, except} %}
  end

  macro force_ssl(only = nil, except = nil)
    # TODO:: support more options like HSTS headers
    {% if only %}
      {% if !only.is_a?(ArrayLiteral) %}
        {% only = [only.id] %}
      {% else %}
        {% only = only.map(&.id) %}
      {% end %}
    {% end %}
    {% if except %}
      {% if !except.is_a?(ArrayLiteral) %}
        {% except = [except.id] %}
      {% else %}
        {% except = except.map(&.id) %}
      {% end %}
    {% end %}
    {% LOCAL_FORCE[:force] = {only, except} %}
  end

  macro force_tls(only = nil, except = nil)
    force_ssl({{only}}, {{except}})
  end

  macro param(name)
    # TODO:: extract type and name etc
    # safe_params == hash of extracted params
  end

  # ===============
  # Helper methods:
  # ===============
  def request_protocol
    ActionController::Support.request_protocol(@request)
  end

  def remote_endpoint_ip
    return @client_ip if @client_ip

    @client_ip = @request.headers["X-Forwarded-Proto"]? || @request.headers["X-Real-IP"]?

    if @client_ip.nil?
      forwarded = @request.headers["Forwarded"]?
      if forwarded
        match = forwarded.match(/for=(.+?)(;|$)/i)
        if match
          ip = match[0]
          ip = ip.split(/=|;/i)[1]
          @client_ip = ip if ip && !["_hidden", "_secret", "unknown"].includes?(ip)
        end
      end

      @client_ip = "127.0.0.1" unless @client_ip
    end

    @client_ip
  end
end
