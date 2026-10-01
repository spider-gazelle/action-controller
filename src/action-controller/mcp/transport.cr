module ActionController::MCPServer
  # implements the [Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#streamable-http) transport
  class Transport
    SESSION_HEADER = "Mcp-Session-Id"
    VERSION_HEADER = "MCP-Protocol-Version"
    KEEPALIVE      = 25.seconds

    getter sessions : SessionStore = SessionStore.new
    getter protocol : Protocol

    def initialize(route_handler : Router::RouteHandler)
      @protocol = Protocol.new(Invoker.new(route_handler))
    end

    # client to server messages
    def post(context : HTTP::Server::Context) : HTTP::Server::Context
      return context unless valid_origin?(context) && valid_version?(context)

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
      return context unless valid_origin?(context) && valid_version?(context)
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
      return context unless valid_origin?(context)
      return context unless session = find_session(context)
      @sessions.delete(session.id)
      context.response.status = HTTP::Status::NO_CONTENT
      context
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
