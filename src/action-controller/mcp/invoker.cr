require "base64"
require "http/client"
require "uri"

module ActionController::MCPServer
  # dispatches tool calls to the application routes in-process
  class Invoker
    def initialize(@route_handler : Router::RouteHandler)
    end

    # raised when the arguments can't be mapped onto the route
    class ArgumentError < ::ArgumentError
    end

    # runs the route and returns a `CallToolResult` JSON string
    def call(tool : Tool, arguments : Hash(String, JSON::Any), origin : HTTP::Request) : String
      request = build_request(tool, arguments, origin)
      response_io = IO::Memory.new
      response = HTTP::Server::Response.new(response_io)
      context = HTTP::Server::Context.new(request, response)

      begin
        @route_handler.call(context)
        response.close
      rescue error
        Log.error(exception: error) { "MCP tool #{tool.name} failed" }
        return MCPServer.tool_result("500 Internal Server Error", error: true)
      end

      response_io.rewind
      to_result HTTP::Client::Response.from_io(response_io)
    rescue error : ArgumentError
      MCPServer.tool_result(error.message.as(String), error: true)
    end

    # :nodoc:
    def build_request(tool : Tool, arguments : Hash(String, JSON::Any), origin : HTTP::Request) : HTTP::Request
      headers = HTTP::Headers.new
      MCPServer.forward_headers.each do |header|
        if values = origin.headers.get?(header)
          headers[header] = values
        end
      end
      headers["Host"] = origin.headers["Host"] if origin.headers.has_key?("Host")
      headers["Accept"] = "application/json, */*;q=0.5"

      query = URI::Params.new
      tool.params.each do |param|
        next unless value = arguments[param.name]?
        next if value.raw.nil?
        case param.in
        when "query"  then query.add(param.name, param_value(value))
        when "header" then headers[param.name] = param_value(value)
        end
      end

      body = nil
      if (body_key = tool.body) && (body_value = arguments[body_key]?)
        headers["Content-Type"] = "application/json"
        body = body_value.to_json
      end

      resource = build_path(tool, arguments)
      resource = "#{resource}?#{query}" unless query.empty?

      request = HTTP::Request.new(tool.verb.upcase, resource, headers, body)
      request.remote_address = origin.remote_address
      request
    end

    private def build_path(tool : Tool, arguments : Hash(String, JSON::Any)) : String
      segments = tool.path.split('/').compact_map do |segment|
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
