module ActionController::MCPServer
  # :nodoc:
  # MCP prompts are routes that are not exposed via HTTP
  class PromptRouter < Composition
    def initialize(composition : Composition = Composition.default)
      super([] of Placement, false)
      composition.register_internal(self)
    end
  end

  # implements the [Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)
  # transport, statelessly. Each POST is handled on its own, so the requests of a client can
  # be served by any instance of the application.
  #
  # 2026-07-28 requests carry their protocol version and client capabilities in `_meta`,
  # earlier versions start with `initialize` and no session is created
  class Transport
    VERSION_HEADER         = "MCP-Protocol-Version"
    METHOD_HEADER          = "Mcp-Method"
    NAME_HEADER            = "Mcp-Name"
    RESOURCE_METADATA_PATH = "/.well-known/oauth-protected-resource"

    META_VERSION      = "io.modelcontextprotocol/protocolVersion"
    META_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities"
    META_SERVER_INFO  = "io.modelcontextprotocol/serverInfo"
    META_SUBSCRIPTION = "io.modelcontextprotocol/subscriptionId"

    # methods that name a tool, prompt or resource in the `Mcp-Name` header
    NAMED_METHODS = {"tools/call" => "name", "prompts/get" => "name", "resources/read" => "uri"}

    # 2026-07-28 onwards is modern, earlier versions start with `initialize`
    enum Era
      Legacy
      Modern
    end

    getter auth_cache : AuthCache = AuthCache.new
    getter protocol : Protocol

    # the path the transport is mounted at, a template for controller endpoints
    getter path : String

    # the path params bound from the URL, for controller endpoints
    getter bound : Array(String)

    # `endpoint: true` serves the controller endpoint mounted at `path`
    def initialize(route_handler : Router::RouteHandler, @path : String = "/mcp", endpoint : Bool = false, composition : Composition = Composition.default)
      @invoker = Invoker.new(route_handler, PromptRouter.new(composition).route_handler)
      @protocol = Protocol.new(@invoker, endpoint ? @path : nil, composition)
      @bound = endpoint ? Endpoint.bound_params(@path) : [] of String
    end

    # client to server messages
    def post(context : HTTP::Server::Context) : HTTP::Server::Context
      return context unless valid_origin?(context) && authenticated?(context)

      message = begin
        JSON.parse(context.request.body.try(&.gets_to_end) || "").as_h?
      rescue JSON::ParseException
        return rpc_error(context, nil, RPCError::PARSE_ERROR, "Parse error", HTTP::Status::BAD_REQUEST)
      end
      return rpc_error(context, nil, RPCError::INVALID_REQUEST, "Invalid request", HTTP::Status::BAD_REQUEST) unless message

      id = message["id"]?
      method = message["method"]?.try(&.as_s?)

      # responses and notifications are acknowledged, there's nothing to do
      if method.nil? || id.nil?
        return accepted(context) if method || message.has_key?("result") || message.has_key?("error")
        return rpc_error(context, id, RPCError::INVALID_REQUEST, "Invalid request", HTTP::Status::BAD_REQUEST)
      end

      params = message["params"]?.try(&.as_h?) || {} of String => JSON::Any
      return initialize_server(context, id, params) if method == "initialize"
      return context unless era = era(context, id, method, params)

      modern = era.modern?
      return listen(context, id) if modern && method == "subscriptions/listen"

      begin
        result = @protocol.handle(method, params, context.request, bound_values(context), modern)
      rescue error : RPCError
        # unknown methods are a 404, so clients can tell them apart from legacy servers
        status = modern && error.code == RPCError::METHOD_NOT_FOUND ? HTTP::Status::NOT_FOUND : HTTP::Status::OK
        return rpc_error(context, id, error.code, error.message.as(String), status)
      rescue Unauthorized
        # the credentials are no longer valid, prompt the client to re-authenticate
        AuthCache.fingerprint(context.request).try { |fingerprint| @auth_cache.delete(fingerprint) }
        return unauthorized(context, invalid_token: true)
      end

      result = complete(result, context.request, cacheable: Protocol::CACHEABLE.includes?(method)) if modern
      respond(context, HTTP::Status::OK, "application/json", rpc_result(id, result))
    end

    # there are no event streams or sessions, so GET and DELETE aren't supported
    def method_not_allowed(context : HTTP::Server::Context) : HTTP::Server::Context
      context.response.headers["Allow"] = "POST"
      respond(context, HTTP::Status::METHOD_NOT_ALLOWED, "text/plain", "MCP requests are POSTed")
    end

    # OAuth 2.0 protected resource metadata, see `MCPServer.resource_metadata`
    def resource_metadata(context : HTTP::Server::Context) : HTTP::Server::Context
      builder = MCPServer.resource_metadata
      return respond(context, HTTP::Status::NOT_FOUND, "text/plain", "resource metadata not configured") unless builder

      context.response.headers["Access-Control-Allow-Origin"] = "*"
      metadata = builder.call(context.request)
      resource = context.request.path.lchop(RESOURCE_METADATA_PATH)
      respond(context, HTTP::Status::OK, "application/json", metadata.to_json(public_url(context.request, resource)))
    end

    # checks the request is authenticated when authentication is enabled
    private def authenticated?(context) : Bool
      return true unless MCPServer.auth_enabled?

      request = context.request
      fingerprint = AuthCache.fingerprint(request)
      return true if fingerprint && @auth_cache.valid?(fingerprint)

      permitted = if authenticator = MCPServer.authenticator
                    authenticator.call(request)
                  elsif probe = MCPServer.auth_probe
                    @invoker.probe(probe, request)
                  else
                    # credentials are validated by the routes when tools are called
                    !fingerprint.nil?
                  end

      if permitted
        @auth_cache.store(fingerprint, MCPServer.auth_cache_ttl) if fingerprint
        true
      else
        unauthorized(context, invalid_token: !fingerprint.nil?)
        false
      end
    end

    # responds with a challenge that prompts MCP clients to (re)authenticate
    private def unauthorized(context, invalid_token : Bool) : HTTP::Server::Context
      request = context.request
      params = [] of String
      if builder = MCPServer.resource_metadata
        params << %(resource_metadata="#{public_url(request, RESOURCE_METADATA_PATH + request.path)}")
        if scopes = builder.call(request).scopes_supported
          params << %(scope="#{scopes.join(' ')}") unless scopes.empty?
        end
      end
      params << %(error="invalid_token") if invalid_token

      context.response.headers["WWW-Authenticate"] = params.empty? ? "Bearer" : "Bearer #{params.join(", ")}"
      rpc_error(context, nil, RPCError::INVALID_REQUEST, "Unauthorized", HTTP::Status::UNAUTHORIZED)
    end

    # the public URL of a path on this server
    private def public_url(request : HTTP::Request, path : String) : String
      host = request.headers["Host"]? || "localhost"
      scheme = request.headers["X-Forwarded-Proto"]?.try(&.split(',').first.strip.presence)
      scheme ||= loopback?(request.hostname) ? "http" : "https"
      "#{scheme}://#{host}#{path}"
    end

    private def loopback?(hostname : String?) : Bool
      return true if hostname.nil?
      hostname == "localhost" || hostname == "::1" || hostname == "[::1]" || hostname.starts_with?("127.")
    end

    # starts a legacy (pre 2026-07-28) conversation, no session is created
    private def initialize_server(context, id : JSON::Any, params : Hash(String, JSON::Any)) : HTTP::Server::Context
      requested = params["protocolVersion"]?.try(&.as_s?)
      version = LEGACY_VERSIONS.includes?(requested) ? requested.as(String) : LEGACY_VERSIONS.first
      # an endpoint's instructions can fail, i.e. for an unknown resource
      result = begin
        @protocol.initialize_result(version, context.request, bound_values(context))
      rescue error : RPCError
        return rpc_error(context, id, error.code, error.message.as(String))
      rescue Unauthorized
        AuthCache.fingerprint(context.request).try { |fingerprint| @auth_cache.delete(fingerprint) }
        return unauthorized(context, invalid_token: true)
      end
      respond(context, HTTP::Status::OK, "application/json", rpc_result(id, result))
    end

    # the protocol era of the request, `nil` if it was rejected. Modern requests must carry
    # the protocol version and client capabilities in `_meta`, matched by the version,
    # method and name headers
    private def era(context, id : JSON::Any, method : String, params : Hash(String, JSON::Any)) : Era?
      headers = context.request.headers
      header = headers[VERSION_HEADER]?
      meta = params["_meta"]?.try(&.as_h?)
      version = meta.try(&.[META_VERSION]?)

      unless version
        # legacy clients without the header are assumed to be 2025-03-26
        return Era::Legacy if header.nil? || LEGACY_VERSIONS.includes?(header)
        return unsupported_version(context, id, header) unless MODERN_VERSIONS.includes?(header)
        return invalid_meta(context, id, "Missing _meta #{META_VERSION}")
      end

      version = version.as_s?
      return invalid_meta(context, id, "Invalid _meta #{META_VERSION}") unless version
      return unsupported_version(context, id, version) unless MODERN_VERSIONS.includes?(version)
      return invalid_meta(context, id, "Missing _meta #{META_CAPABILITIES}") unless meta.try(&.[META_CAPABILITIES]?).try(&.as_h?)

      return header_mismatch(context, id, VERSION_HEADER) unless header == version
      return header_mismatch(context, id, METHOD_HEADER) unless headers[METHOD_HEADER]? == method
      if field = NAMED_METHODS[method]?
        name = headers[NAME_HEADER]?.try { |value| decode_header(value) }
        return header_mismatch(context, id, NAME_HEADER) unless name && name == params[field]?.try(&.as_s?)
      end
      Era::Modern
    end

    # header values that aren't plain ASCII are sent as `=?base64?<value>?=`, `nil` if invalid
    private def decode_header(value : String) : String?
      return value unless value.starts_with?("=?base64?") && value.ends_with?("?=")
      decoded = Base64.decode_string(value[9...-2])
      decoded if decoded.valid_encoding?
    rescue Base64::Error
      nil
    end

    private def unsupported_version(context, id : JSON::Any, requested : String) : Nil
      data = {supported: PROTOCOL_VERSIONS, requested: requested}
      rpc_error(context, id, RPCError::UNSUPPORTED_PROTOCOL_VERSION, "Unsupported protocol version", HTTP::Status::BAD_REQUEST, data)
      nil
    end

    private def invalid_meta(context, id : JSON::Any, message : String) : Nil
      rpc_error(context, id, RPCError::INVALID_PARAMS, message, HTTP::Status::BAD_REQUEST)
      nil
    end

    private def header_mismatch(context, id : JSON::Any, header : String) : Nil
      rpc_error(context, id, RPCError::HEADER_MISMATCH, "Header mismatch: #{header} is missing or doesn't match the request body", HTTP::Status::BAD_REQUEST)
      nil
    end

    # there's nothing to subscribe to, the lists never change, so the subscription is
    # acknowledged with no notifications and then completed
    private def listen(context, id : JSON::Any) : HTTP::Server::Context
      response = context.response
      response.content_type = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"
      subscription = {META_SUBSCRIPTION => id}
      write_event(response, {jsonrpc: "2.0", method: "notifications/subscriptions/acknowledged", params: {notifications: {} of String => String, _meta: subscription}}.to_json)
      write_event(response, rpc_result(id, {resultType: "complete", _meta: subscription}.to_json))
      context
    end

    # adds the 2026-07-28 result fields: the result type, the server info and the cache
    # hints of cacheable results. `result` is always a JSON object built by `Protocol`
    private def complete(result : String, request : HTTP::Request, cacheable : Bool) : String
      fields = JSON.build do |json|
        json.object do
          json.field "resultType", "complete"
          if cacheable
            json.field "ttlMs", MCPServer.cache_ttl.total_milliseconds.to_i64
            # results can depend on the user's credentials
            json.field "cacheScope", MCPServer.auth_enabled? ? "private" : "public"
          end
          json.field "_meta" do
            json.object { json.field(META_SERVER_INFO) { @protocol.server_info(json, request) } }
          end
        end
      end
      body = result.lstrip.lchop('{').lstrip
      body.starts_with?('}') ? fields : "#{fields.rchop('}')},#{body}"
    end

    # the path params bound from the request URL, for controller endpoints
    private def bound_values(context) : Hash(String, String)
      return {} of String => String if @bound.empty?
      params = context.route_params
      values = {} of String => String
      @bound.each do |name|
        if value = params[name]?
          values[name] = value
        end
      end
      values
    end

    # protects against DNS rebinding attacks
    private def valid_origin?(context) : Bool
      request = context.request
      origin = request.headers["Origin"]?
      return true if origin.nil?

      allowed = MCPServer.allowed_origins
      return true if allowed.includes?("*") || allowed.includes?(origin)

      uri = URI.parse(origin)
      authority = uri.port ? "#{uri.host}:#{uri.port}" : uri.host
      return true if authority && authority == request.headers["Host"]?

      rpc_error(context, nil, RPCError::INVALID_REQUEST, "Origin not permitted", HTTP::Status::FORBIDDEN)
      false
    end

    private def accepted(context) : HTTP::Server::Context
      context.response.status = HTTP::Status::ACCEPTED
      context
    end

    private def respond(context, status : HTTP::Status, content_type : String, body : String) : HTTP::Server::Context
      response = context.response
      response.status = status
      response.content_type = content_type
      response << body
      context
    end

    private def write_event(response : HTTP::Server::Response, message : String) : Nil
      response << "event: message\ndata: " << message << "\n\n"
      response.flush
    end

    private def rpc_result(id : JSON::Any, result : String) : String
      JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id", id
          json.field("result") { json.raw result }
        end
      end
    end

    private def rpc_error(context, id : JSON::Any?, code : Int32, message : String, status : HTTP::Status = HTTP::Status::OK, data = nil) : HTTP::Server::Context
      body = JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id", id
          json.field "error" do
            json.object do
              json.field "code", code
              json.field "message", message
              json.field "data", data if data
            end
          end
        end
      end
      respond(context, status, "application/json", body)
    end
  end
end
