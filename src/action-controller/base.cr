require "openssl/sha1"
require "./body_parser"
require "./responders"
require "./session"
require "./support"
require "uri"
require "./router/builder"

abstract class ActionController::Base
  include ActionController::Route::Builder
  include ActionController::Responders

  # Route IDs params
  DEFAULT_PARAM_ID = {} of Nil => Nil

  macro id_param(id)
    {% DEFAULT_PARAM_ID[@type.id] = id %}
  end

  # Template support
  TEMPLATE_LAYOUT = {} of Nil => Nil
  TEMPLATE_PATH   = {} of Nil => Nil
  {% TEMPLATE_PATH[@type.id] = "./src/views/" %}

  macro layout(filename = nil)
    {% if filename == nil || filename.empty? %}
      {% TEMPLATE_LAYOUT[@type.id] = nil %}
    {% else %}
      {% TEMPLATE_LAYOUT[@type.id] = filename %}
    {% end %}
  end

  macro template_path(path)
    {% if path.id.ends_with?("/") %}
      {% TEMPLATE_PATH[@type.id] = path %}
    {% else %}
      {% TEMPLATE_PATH[@type.id] = path + "/" %}
    {% end %}
  end

  macro template(template = nil, partial = nil, layout = nil, io = nil)
    {% if !(template || partial) %}
      {% raise "template or partial required!" %}
    {% else %}
      {% filename = partial || template %}
      {% layout = layout || TEMPLATE_LAYOUT[@type.id] %}

      {% if (partial || !layout) && io %}
        %content = render_template({{filename}}, {{io}})
      {% else %}
        %content = render_template({{filename}})
      {% end %}

      {% if !partial %}
        {% if layout %}
          {% if io %}
            content = %content
            render_template({{layout}}, {{io}})
          {% else %}
            content = %content
            render_template({{layout}})
          {% end %}
        {% else %}
          %content
        {% end %}
      {% else %}
        %content
      {% end %}
    {% end %}
  end

  macro partial(partial, io = nil)
    {% if io %}
      template(partial: {{partial}}, io: {{io}})
    {% else %}
      template(partial: {{partial}})
    {% end %}
  end

  private macro render_template(filename, io = nil)
    {% if io %}
      Kilt.embed({{TEMPLATE_PATH[@type.id] + filename}}, {{io}})
    {% else %}
      Kilt.render({{TEMPLATE_PATH[@type.id] + filename}})
    {% end %}
  end

  # Base route => klass name
  CONCRETE_CONTROLLERS = {} of Nil => Nil
  FILTER_TYPES         = %w(ROUTES BEFORE AROUND AFTER RESCUE FORCE SKIP)

  {% for ftype in FILTER_TYPES %}
    # klass => {function => options}
    {{ftype.id}}_MAPPINGS = {} of Nil => Nil
  {% end %}

  macro __build_filter_inheritance_macros__
    {% for ftype in FILTER_TYPES %}
      {% ltype = ftype.downcase %}

      macro __inherit_{{ltype.id}}_filters__
        \{% {{ftype.id}}_MAPPINGS[@type.name.id] = LOCAL_{{ftype.id}} %}
        \{% klasses = [@type.name.id] %}
        \{% @type.ancestors.each { |name| klasses.unshift(name) } %}

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
    "index"   => {"get", "/", false},
    "new"     => {"get", "/new", false},
    "create"  => {"post", "/", false},
    "show"    => {"get", "/:id", true},
    "edit"    => {"get", "/:id/edit", true},
    "update"  => {"patch", "/:id", true},
    "replace" => {"put", "/:id", true},
    "destroy" => {"delete", "/:id", true},
  }

  def initialize(@context : HTTP::Server::Context, @action_name = :index, @__head_request__ = false)
    @render_called = false
  end

  getter context
  getter action_name : Symbol
  getter render_called : Bool
  getter __session__ : Session?
  getter __cookies__ : HTTP::Cookies?

  def session : Session
    @__session__ ||= Session.from_cookies(cookies)
  end

  def cookies : HTTP::Cookies
    @__cookies__ ||= @context.request.cookies
  rescue error
    Log.warn(exception: error) { "error parsing cookies" }
    @__cookies__ = HTTP::Cookies.new
  end

  delegate request, response, route_params, to: @context

  delegate query_params, to: @context.request

  getter params : URI::Params do
    _params = ActionController::Base.extract_params(@context)
    # Add form data to params, lowest preference
    ctype = request_content_type
    @files, @form_data = ActionController::BodyParser.extract_form_data(request, ctype, _params) if ctype
    _params
  end

  # Extracts query and route params into a single `URI::Params` instance
  def self.extract_params(context : HTTP::Server::Context) : URI::Params
    params = URI::Params.new
    # duplicate the query_params
    qparams = context.request.query_params
    qparams.each do |key, _|
      params.set_all(key, qparams.fetch_all(key).dup)
    end

    # Add route params to the HTTP params
    # giving preference to route params
    context.route_params.each do |key, value|
      values = params.fetch_all(key)
      values.unshift value
      params.set_all(key, values)
    end

    params
  end

  @form_data : URI::Params?

  def form_data
    return @form_data if @params
    params
    @form_data
  end

  @files : Hash(String, Array(ActionController::BodyParser::FileUpload))? = nil

  def files : Hash(String, Array(ActionController::BodyParser::FileUpload))?
    return @files if @params
    params
    @files
  end

  @__content_type__ : String?

  def request_content_type : String?
    @__content_type__ ||= ActionController::Support.content_type(request.headers)
  end

  macro inherited
    # default namespace based on class
    NAMESPACE = [{{"/" + @type.name.stringify.underscore.gsub(/\:\:/, "/")}}]

    {% for ftype in FILTER_TYPES %}
      # function => options
      LOCAL_{{ftype.id}} = {} of Nil => Nil
      {{ftype.id}} = {} of Nil => Nil
    {% end %}

    {% TEMPLATE_LAYOUT[@type.id] = TEMPLATE_LAYOUT[@type.ancestors[0].id] %}
    {% TEMPLATE_PATH[@type.id] = TEMPLATE_PATH[@type.ancestors[0].id] %}

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
      {% for method, index in @type.methods %}
        {% name = method.name.stringify %}
        {% args = CRUD_METHODS[name] %}

        # see if this method is already added
        {% matching_method = false %}
        {% for path, details in ROUTES %}
          {% function_name = details[6] %}
          {% if function_name == name.id %}
            {% matching_method = true %}
          {% end %}
        {% end %}

        {% if args && !matching_method %}
          # check the method isn't annotated
          {% magic_method = true %}
          {% for route_method in {AC::Route::GET, AC::Route::POST, AC::Route::PUT, AC::Route::PATCH, AC::Route::DELETE, AC::Route::OPTIONS, AC::Route::Filter, AC::Route::Exception} %}
            {% for ann, idx in method.annotations(route_method) %}
              {% magic_method = false %}
            {% end %}
          {% end %}

          # add the magic method to the routes
          {% if magic_method %}
            {% if args[2] && DEFAULT_PARAM_ID[@type.id] %}
              {% new_default_param = args[1].gsub(/\:id/, ":" + DEFAULT_PARAM_ID[@type.id].id.stringify) %}
              {% ROUTES[args[0] + new_default_param] = {args[0], new_default_param, nil, nil, false, name.id, name.id} %}
            {% else %}
              {% ROUTES[args[0] + args[1]] = {args[0], args[1], nil, nil, false, name.id, name.id} %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}

      # Create functions as required for errors
      # Skip the generating methods for existing handlers
      {% for klass, details in RESCUE %}
        {% block = details[1] %}
        {% if block != nil %}
          def {{details[0]}}({{*details[1].args}})
            {{details[1].body}}
          end
        {% end %}
      {% end %}

      # Helper for obtaining base route
      class_getter base_route = {{NAMESPACE[0]}}
      # :ditto:
      delegate base_route, to: self.class
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

      # Generate functions for each route
      {% for _key, details in ROUTES %}
        {% http_method = details[0] %}
        {% route_path = details[1] %}
        {% is_websocket = details[4] %}
        {% reference_name = details[5] %}
        {% function_name = details[6] %}

        def self.{{(http_method.id.stringify + "_" + NAMESPACE[0].id.stringify + route_path.id.stringify).gsub(/\/|\-|\~|\*|\:|\./, "_").id}}(context, head_request)
          # Check if force SSL is set and redirect to HTTPS if HTTP
          {% force = false %}
          {% if FORCE[:force] %}
            {% options = FORCE[:force] %}
            {% only = options[0] %}
            {% if only != nil && only.includes?(reference_name) %} # only
              {% force = true %}
            {% else %}
              {% except = options[1] %}
              {% if except != nil && !except.includes?(reference_name) %} # except
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
              response << "WebSocket Secure (wss://) connection required"
            {% else %}
              ActionController::Support.redirect_to_https(context)
            {% end %}
            else
          {% end %}

          # Create an instance of the controller
          instance = {{@type.name}}.new(context, :{{reference_name}}, head_request)

          # Check for errors
          {% if !RESCUE.empty? %}
            begin
          {% end %}

          # Check if there is a skip on this method
          {% skipping = [] of Nil %}
          {% for method, options in SKIP %}
            {% only = options[0] %}
            {% except = options[1] %}
            {% if only == nil && except == nil %}
              {% skipping = [method] + skipping %}
            {% elsif only != nil && only.includes?(reference_name) %}
              {% skipping = [method] + skipping %}
            {% elsif except != nil && !except.includes?(reference_name) %}
              {% skipping = [method] + skipping %}
            {% end %}
          {% end %}

          # Execute the around filters
          {% around_actions = AROUND.keys %}
          {% for method, options in AROUND %}
            {% only = options[0] %}
            {% if only != nil && !only.includes?(reference_name) %} # only
              {% around_actions = around_actions.reject(&.==(method)) %}
            {% else %}
              {% except = options[1] %}
              {% if except != nil && except.includes?(reference_name) %} # except
                {% around_actions = around_actions.reject(&.==(method)) %}
              {% end %}
            {% end %}
          {% end %}
          {% around_actions = around_actions.reject { |act| skipping.includes?(act) } %}

          {% if !around_actions.empty? %}
            ActionController::Base.__yield__(instance) do
              {% for action in around_actions %}
                  break if render_called
                  {{action}} do
              {% end %}
          {% end %}

          # Execute the before filters
          {% before_actions = BEFORE.keys %}
          {% for method, options in BEFORE %}
            {% only = options[0] %}
            {% if only != nil && !only.includes?(reference_name) %} # only
              {% before_actions = before_actions.reject(&.==(method)) %}
            {% else %}
              {% except = options[1] %}
              {% if except != nil && except.includes?(reference_name) %} # except
                {% before_actions = before_actions.reject(&.==(method)) %}
              {% end %}
            {% end %}
          {% end %}
          {% before_actions = before_actions.reject { |act| skipping.includes?(act) } %}

          {% if !before_actions.empty? %}
            {% if around_actions.empty? %}
              ActionController::Base.__yield__(instance) do
            {% end %}
              {% for action in before_actions %}
                break if render_called
                {{action}}
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
                    instance.{{function_name}}(ws_session)
                    ws_session.run
                  ensure
                    io.close
                  end
                end
              else
                response = context.response
                response.status_code = {{STATUS_CODES[:upgrade_required]}}
                response.content_type = MIME_TYPES[:text]
                response << "This service requires use of the WebSocket protocol"
              end
            {% else %}
              instance.{{function_name}}
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
            {% if only != nil && !only.includes?(reference_name) %} # only
              {% after_actions = after_actions.reject(&.==(method)) %}
            {% else %}
              {% except = options[1] %}
              {% if except != nil && except.includes?(reference_name) %} # except
                {% after_actions = after_actions.reject(&.==(method)) %}
              {% end %}
            {% end %}
          {% end %}
          {% after_actions = after_actions.reject { |act| skipping.includes?(act) } %}

          {% if !after_actions.empty? %}
            ActionController::Base.__yield__(instance) do
              {% for action in after_actions %}
                {{action}}
              {% end %}
            end
          {% end %}

          # Check if session needs to be written
          if !instance.render_called
            session = instance.__session__
            session.encode(context.response.cookies) if session && session.modified
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

      # Routes call the functions generated above
      def self.__init_routes__(router)
        {% for _key, details in ROUTES %}
          {% http_method = details[0] %}
          {% route_path = details[1] %}
          router.{{http_method.id}} {{(NAMESPACE[0].id.stringify + route_path.id.stringify).gsub(/\/\//, "/")}}, &->{{(http_method.id.stringify + "_" + NAMESPACE[0].id.stringify + route_path.id.stringify).gsub(/\/|\-|\~|\*|\:|\./, "_").id}}(HTTP::Server::Context, Bool)
        {% end %}

        nil
      end

      # Helper methods for performing redirect_to calls
      {% for _key, details in ROUTES %}
        {% reference_name = details[5] %}
        {% route_path = details[1] %}
        def self.{{reference_name}}(hash_parts : Hash((String | Symbol), (Nil | Bool | Int32 | Int64 | Float32 | Float64 | String | Symbol))? = nil, **tuple_parts)
          route = "{{NAMESPACE[0].id}}{{route_path.id}}".gsub("//", "/")
          ActionController::Support.build_route(route, hash_parts, **tuple_parts)
        end
      {% end %}

      def self.__route_list__
        [
          # "Class", :name, :verb, "route"
          {% for _key, details in ROUTES %}
            {% http_method = details[0] %}
            {% route_path = details[1] %}
            {% reference_name = details[5] %}
            { "{{@type.name}}", :{{reference_name}}, :{{http_method.id}}, "{{NAMESPACE[0].id}}{{route_path.id}}".gsub("//", "/")},
          {% end %}
        ]
      end
    {% end %}
  end

  macro base(name = nil)
    {% if name == nil || name.empty? || name == "/" %}
      {% NAMESPACE[0] = "/" %}
    {% else %}
      {% if name.id.stringify.starts_with?("/") %}
        {% NAMESPACE[0] = name.id.stringify %}
      {% else %}
        {% NAMESPACE[0] = "/" + name.id.stringify %}
      {% end %}
    {% end %}
  end

  # Define each method for supported http methods except head (which is meta)
  {% for http_method in ::ActionController::Router::HTTP_METHODS.reject(&.==("head")) %}
    macro {{http_method.id}}(path, function = nil, annotations = nil, reference = nil, &block)
      \{% unless function %}
        \{% function = {{http_method}} + path.gsub(/\/|\-|\~|\*|\:|\./, "_") %}
      \{% end %}
      \{% LOCAL_ROUTES[{{http_method}} + path] = { {{http_method}}, path, annotations, block, false, (reference || function).id, function.id } %}
      \{% if annotations %}
        \{% annotations = [annotations] unless annotations.is_a?(ArrayLiteral) %}
        \{% for ann in annotations %}
          \{{ ann.id }}
        \{% end %}
      \{% end %}
      \{{ ("def " + function.id.stringify + "(").id }}
        \{{*block.args}}
      \{{ ")".id }}
        \{{block.body}}
      \{{ "end".id }}
    end
  {% end %}

  macro ws(path, function = nil, annotations = nil, reference = nil, &block)
    {% unless function %}
      {% function = "ws" + path.gsub(/\/|\-|\~|\*|\:|\./, "_") %}
    {% end %}
    {% LOCAL_ROUTES["ws" + path] = {"get", path, annotations, block, true, (reference || function).id, function.id} %}
    {% if annotations %} #
      {% annotations = [annotations] unless annotations.is_a?(ArrayLiteral) %}
      {% for ann in annotations %}
        {{ ann.id }}
      {% end %}
    {% end %}
    def {{function.id}}({{*block.args}})
      {{block.body}}
    end
  end

  macro rescue_from(error_class, method = nil, &block)
    {% if method %}
      {% LOCAL_RESCUE[error_class] = {method.id, nil} %}
    {% else %}
      {% method = error_class.stringify.underscore.gsub(/\:\:/, "_") %}
      {% LOCAL_RESCUE[error_class] = {method.id, block} %}
    {% end %}
  end

  macro __define_filter_macro__(name, store, method = nil)
    macro {{name.id}}({% if method.nil? %} method, {% end %} only = nil, except = nil)
    {% if method %}
      \{% method = {{method}} %}
    {% else %}
      \{% method = method.id %}
    {% end %}
      \{% prev_only = nil %}
      \{% prev_except = nil %}
      \{% if existing = {{store}}[method] %}
        \{% prev_only = existing[0] %}
        \{% prev_except = existing[1] %}
      \{% end %}
      \{% if only %}
        \{% if !only.is_a?(ArrayLiteral) %}
          \{% only = prev_only ? prev_only + [only.id] : [only.id] %}
        \{% else %}
          \{% only = prev_only ? prev_only + only.map(&.id) : only.map(&.id) %}
        \{% end %}
      \{% else %}
        \{% only = prev_only %}
      \{% end %}
      \{% if except %}
        \{% if !except.is_a?(ArrayLiteral) %}
          \{% except = prev_except ? prev_except + [except.id] : [except.id] %}
        \{% else %}
          \{% except = prev_except ? prev_except + except.map(&.id) : except.map(&.id) %}
        \{% end %}
      \{% else %}
        \{% except = prev_except %}
      \{% end %}
      \{% {{store}}[method] = {only, except} %}
    end
  end

  __define_filter_macro__(:around_action, LOCAL_AROUND)
  __define_filter_macro__(:before_action, LOCAL_BEFORE)
  __define_filter_macro__(:after_action, LOCAL_AFTER)
  __define_filter_macro__(:skip_action, LOCAL_SKIP)
  __define_filter_macro__(:force_ssl, LOCAL_FORCE, :force)

  macro force_tls(only = nil, except = nil)
    force_ssl({{only}}, {{except}})
  end

  # ===============
  # Helper methods:
  # ===============
  def request_protocol
    ActionController::Support.request_protocol(request)
  end

  @client_ip : String? = nil

  def client_ip : String
    cip = @client_ip
    return cip if cip

    request = @context.request
    cip = request.headers["X-Forwarded-For"]? || request.headers["X-Real-IP"]?

    if cip.nil?
      forwarded = request.headers["Forwarded"]?
      if forwarded
        match = forwarded.match(/for=(.+?)(;|$)/i)
        if match
          ip = match[0]
          ip = ip.split(/=|;/i)[1]
          cip = ip if ip && !["_hidden", "_secret", "unknown"].includes?(ip)
        end
      end

      cip = (request.remote_address.try(&.to_s) || "127.0.0.1").split(":")[0] unless cip
    end

    @client_ip = cip
    cip
  end
end
