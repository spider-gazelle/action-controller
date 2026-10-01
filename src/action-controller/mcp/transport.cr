module ActionController::MCPServer
  # :nodoc:
  # MCP prompts are routes that are not exposed via HTTP
  class PromptRouter
    include Router

    def initialize
      # expanded when the method is used, once all the routes are known
      {% for klass in ::ActionController::Base::CONCRETE_CONTROLLERS.keys %}
        {{klass}}.__init_internal_routes__(self)
      {% end %}
    end
  end

  # implements the [Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#streamable-http) transport
  class Transport
    SESSION_HEADER         = "Mcp-Session-Id"
    VERSION_HEADER         = "MCP-Protocol-Version"
    KEEPALIVE              = 25.seconds
    RESOURCE_METADATA_PATH = "/.well-known/oauth-protected-resource"

    getter sessions : SessionStore = SessionStore.new
    getter auth_cache : AuthCache = AuthCache.new
    getter protocol : Protocol

    # the path the transport is mounted at
    getter path : String

    def initialize(route_handler : Router::RouteHandler, @path : String = "/mcp")
      @invoker = Invoker.new(route_handler, PromptRouter.new.route_handler)
      @protocol = Protocol.new(@invoker)
    end

    # client to server messages
    def post(context : HTTP::Server::Context) : HTTP::Server::Context
      return context unless valid_origin?(context) && valid_version?(context) && authenticated?(context)

      message = begin
        JSON.parse(context.request.body.try(&.gets_to_end) || "").as_h?
      rescue JSON::ParseException
        return rpc_error(context, nil, RPCError::PARSE_ERROR, "Parse error", HTTP::Status::BAD_REQUEST)
      end
      return rpc_error(context, nil, RPCError::INVALID_REQUEST, "Invalid request", HTTP::Status::BAD_REQUEST) unless message

      id = message["id"]?
      method = message["method"]?.try(&.as_s?)

      # responses to server requests and notifications are acknowledged
      if method.nil? || id.nil?
        return accepted(context) if method || message.has_key?("result") || message.has_key?("error")
        return rpc_error(context, id, RPCError::INVALID_REQUEST, "Invalid request", HTTP::Status::BAD_REQUEST)
      end

      params = message["params"]?.try(&.as_h?) || {} of String => JSON::Any
      return initialize_session(context, id, params) if method == "initialize"
      return context unless session = find_session(context)

      emitted = [] of String
      begin
        result = @protocol.handle(method, params, session, context.request, emitted)
      rescue error : RPCError
        return rpc_error(context, id, error.code, error.message.as(String))
      rescue Unauthorized
        # the credentials are no longer valid, prompt the client to re-authenticate
        AuthCache.fingerprint(context.request).try { |fingerprint| @auth_cache.delete(fingerprint) }
        return unauthorized(context, invalid_token: true)
      end

      reply = rpc_result(id, result)
      if emitted.empty? || !accepts?(context, "text/event-stream")
        emitted.each { |notification| session.notify(notification) }
        respond(context, HTTP::Status::OK, "application/json", reply)
      else
        # deliver the notifications ahead of the result
        response = context.response
        response.content_type = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        emitted.each { |notification| write_event(response, notification) }
        write_event(response, reply)
        context
      end
    end

    # opens an event stream for server to client messages
    def get(context : HTTP::Server::Context, head_request : Bool) : HTTP::Server::Context
      return context unless valid_origin?(context) && valid_version?(context) && authenticated?(context)
      if head_request || !accepts?(context, "text/event-stream")
        return respond(context, HTTP::Status::METHOD_NOT_ALLOWED, "text/plain", "event stream requires Accept: text/event-stream")
      end
      return context unless session = find_session(context)

      response = context.response
      response.content_type = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.flush

      loop do
        select
        when message = session.notifications.receive?
          break unless message
          write_event(response, message)
        when timeout(KEEPALIVE)
          session.touch
          response << ": keepalive\n\n"
          response.flush
        end
      end
      context
    rescue IO::Error
      # client disconnected
      context
    end

    # terminates the session
    def delete(context : HTTP::Server::Context) : HTTP::Server::Context
      return context unless valid_origin?(context) && authenticated?(context)
      return context unless session = find_session(context)
      @sessions.delete(session.id)
      context.response.status = HTTP::Status::NO_CONTENT
      context
    end

    # OAuth 2.0 protected resource metadata, see `MCPServer.resource_metadata`
    def resource_metadata(context : HTTP::Server::Context) : HTTP::Server::Context
      builder = MCPServer.resource_metadata
      return respond(context, HTTP::Status::NOT_FOUND, "text/plain", "resource metadata not configured") unless builder

      context.response.headers["Access-Control-Allow-Origin"] = "*"
      metadata = builder.call(context.request)
      respond(context, HTTP::Status::OK, "application/json", metadata.to_json(public_url(context.request, @path)))
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
        params << %(resource_metadata="#{public_url(request, RESOURCE_METADATA_PATH + @path)}")
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

    private def initialize_session(context, id : JSON::Any, params : Hash(String, JSON::Any)) : HTTP::Server::Context
      requested = params["protocolVersion"]?.try(&.as_s?)
      version = PROTOCOL_VERSIONS.includes?(requested) ? requested.as(String) : PROTOCOL_VERSIONS.first
      session = @sessions.create(version)
      context.response.headers[SESSION_HEADER] = session.id
      respond(context, HTTP::Status::OK, "application/json", rpc_result(id, @protocol.initialize_result(version)))
    end

    private def find_session(context) : Session?
      unless session_id = context.request.headers[SESSION_HEADER]?
        rpc_error(context, nil, RPCError::INVALID_REQUEST, "Missing #{SESSION_HEADER} header", HTTP::Status::BAD_REQUEST)
        return
      end

      session = @sessions[session_id]?
      rpc_error(context, nil, RPCError::INVALID_REQUEST, "Session not found", HTTP::Status::NOT_FOUND) unless session
      session
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

    private def valid_version?(context) : Bool
      version = context.request.headers[VERSION_HEADER]?
      return true if version.nil? || PROTOCOL_VERSIONS.includes?(version)

      rpc_error(context, nil, RPCError::INVALID_REQUEST, "Unsupported protocol version: #{version}", HTTP::Status::BAD_REQUEST)
      false
    end

    private def accepts?(context, media_type : String) : Bool
      !!context.request.headers["Accept"]?.try(&.includes?(media_type))
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

    private def rpc_error(context, id : JSON::Any?, code : Int32, message : String, status : HTTP::Status = HTTP::Status::OK) : HTTP::Server::Context
      body = JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id", id
          json.field "error" do
            json.object do
              json.field "code", code
              json.field "message", message
            end
          end
        end
      end
      respond(context, status, "application/json", body)
    end
  end
end
