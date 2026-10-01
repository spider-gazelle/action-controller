require "base64"
require "http/client"
require "uri"

module ActionController::MCPServer
  # dispatches tool calls and prompts to the application routes in-process
  class Invoker
    # prompts are internal routes, not accessible via HTTP
    def initialize(@route_handler : Router::RouteHandler, @prompt_handler : Router::RouteHandler = Router::RouteHandler.new)
    end

    # raised when the arguments can't be mapped onto the route
    class ArgumentError < ::ArgumentError
    end

    # runs the route and returns a `CallToolResult` JSON string.
    #
    # raises `Unauthorized` if authentication is enabled and the route responds with a 401
    def call(tool : Tool, arguments : Hash(String, JSON::Any), origin : HTTP::Request) : String
      response = begin
        dispatch build_request(tool, arguments, origin)
      rescue error : ArgumentError
        return MCPServer.tool_result(error.message.as(String), error: true)
      rescue error
        Log.error(exception: error) { "MCP tool #{tool.name} failed" }
        return MCPServer.tool_result("500 Internal Server Error", error: true)
      end

      if response.status.unauthorized? && MCPServer.auth_enabled?
        raise Unauthorized.new("#{tool.name} responded with 401")
      end
      to_result response
    end

    # requests the route provided with the forwarded credentials, returning `true` on success
    def probe(path : String, origin : HTTP::Request) : Bool
      headers = forwarded_headers(origin)
      headers["Accept"] = "application/json"
      request = HTTP::Request.new("GET", path, headers)
      request.remote_address = origin.remote_address
      dispatch(request).status.success?
    rescue error
      Log.error(exception: error) { "MCP auth probe #{path} failed" }
      false
    end

    # renders the prompt and returns a `GetPromptResult` JSON string
    #
    # raises `RPCError` if the prompt can't be rendered and `Unauthorized` if
    # authentication is enabled and the prompt responds with a 401
    def get_prompt(prompt : Prompt, arguments : Hash(String, JSON::Any), origin : HTTP::Request) : String
      prompt.arguments.each do |argument|
        if argument.required? && arguments[argument.name]?.try(&.raw).nil?
          raise RPCError.new(RPCError::INVALID_PARAMS, "missing required argument: #{argument.name}")
        end
      end

      response = begin
        dispatch build("GET", prompt.path, prompt.arguments, nil, arguments, origin), @prompt_handler
      rescue error : ArgumentError
        raise RPCError.new(RPCError::INVALID_PARAMS, error.message.as(String))
      rescue error
        Log.error(exception: error) { "MCP prompt #{prompt.name} failed" }
        raise RPCError.new(RPCError::INTERNAL_ERROR, "prompt #{prompt.name} failed")
      end

      status = response.status
      body = response.body
      if status.unauthorized? && MCPServer.auth_enabled?
        raise Unauthorized.new("#{prompt.name} responded with 401")
      end
      unless status.success?
        code = status.client_error? ? RPCError::INVALID_PARAMS : RPCError::INTERNAL_ERROR
        raise RPCError.new(code, body.empty? ? "#{status.code} #{status.description}" : "#{status.code} #{status.description}: #{body}")
      end

      # prompts render JSON, either a string or an array of messages
      messages = begin
        if text = JSON.parse(body).as_s?
          [::ActionController::PromptMessage.user(text)]
        else
          Array(::ActionController::PromptMessage).from_json(body)
        end
      rescue error : JSON::ParseException | JSON::SerializableError
        Log.error(exception: error) { "MCP prompt #{prompt.name} rendered an invalid response" }
        raise RPCError.new(RPCError::INTERNAL_ERROR, "prompt #{prompt.name} failed")
      end

      JSON.build do |json|
        json.object do
          json.field "description", prompt.description if prompt.description
          json.field "messages" do
            json.array do
              messages.each do |message|
                json.object do
                  json.field "role", message.role.to_s.downcase
                  json.field "content" do
                    json.object do
                      json.field "type", "text"
                      json.field "text", message.text
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # runs the request through the application routes in-process
    def dispatch(request : HTTP::Request, handler : Router::RouteHandler = @route_handler) : HTTP::Client::Response
      response_io = IO::Memory.new
      response = HTTP::Server::Response.new(response_io)
      handler.call HTTP::Server::Context.new(request, response)
      response.close
      response_io.rewind
      HTTP::Client::Response.from_io(response_io)
    end

    # the credential headers copied from the MCP request
    def forwarded_headers(origin : HTTP::Request) : HTTP::Headers
      headers = HTTP::Headers.new
      MCPServer.forward_headers.each do |header|
        if values = origin.headers.get?(header)
          headers[header] = values
        end
      end
      headers["Host"] = origin.headers["Host"] if origin.headers.has_key?("Host")
      headers
    end

    # :nodoc:
    def build_request(tool : Tool, arguments : Hash(String, JSON::Any), origin : HTTP::Request) : HTTP::Request
      build(tool.verb.upcase, tool.path, tool.params, tool.body, arguments, origin)
    end

    # params are `ToolParam` or `PromptArgument`, anything with a name and location
    private def build(verb : String, path : String, params, body_key : String?, arguments : Hash(String, JSON::Any), origin : HTTP::Request) : HTTP::Request
      headers = forwarded_headers(origin)
      headers["Accept"] = "application/json, */*;q=0.5"

      query = URI::Params.new
      params.each do |param|
        next unless value = arguments[param.name]?
        next if value.raw.nil?
        case param.in
        when "query"  then query.add(param.name, param_value(value))
        when "header" then headers[param.name] = param_value(value)
        end
      end

      body = nil
      if body_key && (body_value = arguments[body_key]?)
        headers["Content-Type"] = "application/json"
        body = body_value.to_json
      end

      resource = build_path(path, arguments)
      resource = "#{resource}?#{query}" unless query.empty?

      request = HTTP::Request.new(verb, resource, headers, body)
      request.remote_address = origin.remote_address
      request
    end

    private def build_path(path : String, arguments : Hash(String, JSON::Any)) : String
      segments = path.split('/').compact_map do |segment|
        case segment
        when .starts_with?(':')
          name = segment.lchop(':')
          value = arguments[name]?
          raise ArgumentError.new("missing required argument: #{name}") if value.nil? || value.raw.nil?
          URI.encode_path_segment(param_value(value))
        when .starts_with?("?:"), .starts_with?("*:")
          name = segment[2..]
          value = arguments[name]?
          next if value.nil? || value.raw.nil?
          segment.starts_with?('?') ? URI.encode_path_segment(param_value(value)) : URI.encode_path(param_value(value))
        else
          segment
        end
      end
      path = segments.join('/')
      path.empty? ? "/" : path
    end

    # strings are passed as is, everything else uses its JSON representation
    private def param_value(value : JSON::Any) : String
      value.as_s? || value.to_json
    end

    private def to_result(response : HTTP::Client::Response) : String
      status = response.status
      error = !status.success? && !status.redirection?
      mime = response.mime_type
      media_type = mime.try(&.media_type) || ""
      body = response.body

      if media_type.starts_with?("image/") || media_type.starts_with?("audio/")
        return JSON.build { |json|
          json.object do
            json.field "content" do
              json.array do
                json.object do
                  json.field "type", media_type.starts_with?("image/") ? "image" : "audio"
                  json.field "data", Base64.strict_encode(body)
                  json.field "mimeType", media_type
                end
              end
            end
            json.field "isError", error
          end
        }
      end

      structured = nil
      if !error && media_type.ends_with?("json")
        structured = JSON.parse(body).as_h? rescue nil
      end

      status_line = "#{status.code} #{status.description}"
      text = if body.empty?
               status_line
             elsif error
               "#{status_line}\n#{body}"
             else
               body
             end

      MCPServer.tool_result(text, error: error, structured: structured)
    end
  end

  # :nodoc:
  def tool_result(text : String, error : Bool = false, structured : Hash(String, JSON::Any)? = nil) : String
    JSON.build { |json|
      json.object do
        json.field "content" do
          json.array do
            json.object do
              json.field "type", "text"
              json.field "text", text
            end
          end
        end
        json.field "structuredContent", structured if structured
        json.field "isError", error
      end
    }
  end
end
