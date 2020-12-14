# # Spec route by setting up HTTP::Client
def curl(method : String, path : String, headers = {} of String => String, body : HTTP::Client::BodyType = nil) : HTTP::Client::Response
  client = HTTP::Client.new "localhost", 6000

  head = HTTP::Headers.new
  headers.each do |key, value|
    head[key] = value
  end

  response = nil
  case method
  when "GET"
    response = client.get path, head
  when "POST"
    response = client.post path, head, body: body
  when "PUT"
    response = client.put path, head, body: body
  when "PATCH"
    response = client.patch path, head, body: body
  when "DELETE"
    response = client.delete path, head
  when "HEAD"
    response = client.head path, head
  when "OPTIONS"
    response = client.options path, head
  else
    raise "unknown HTTP Verb: #{method}"
  end

  client.close

  response.not_nil!
end

::CURL_CONTEXT__ = [] of ActionController::Server

macro with_server(&block)
  if ::CURL_CONTEXT__.empty?
    %app = ActionController::Server.new
    ::CURL_CONTEXT__ << %app
    %channel = Channel(Nil).new(1)

    Spec.before_each do
      %app.reload
      %app.socket.bind_tcp("127.0.0.1", 6000, true)
      begin
        File.delete("/tmp/spider-socket.sock")
      rescue
      end
      %app.socket.bind_unix "/tmp/spider-socket.sock"
      spawn do
        %channel.send(nil)
        %app.run
      end
      %channel.receive
    end

    Spec.after_each do
      %app.close
    end
  end

  %app = ::CURL_CONTEXT__[0]

  {% if block.args.size > 0 %}
    {{block.args[0].id}} = %app
  {% end %}

  {{block.body}}
end

# # Creates a context for specing controllers

# Use context by manually instantiating the entire context with IO::Memory in body and output
def context(
  method : String,
  path : String,
  headers : HTTP::Headers? = nil,
  body : String | Bytes | IO | Nil = nil,
  version = "HTTP/1.1",
  response_io = IO::Memory.new,
  **header_opts
)
  headers ||= HTTP::Headers.new
  header_opts.each do |key, value|
    headers.add(key.to_s.split(/-|_/).map(&.capitalize).join("-"), value.to_s)
  end
  response = HTTP::Server::Response.new(response_io, version)
  request = HTTP::Request.new(method, path, headers, body, version)
  HTTP::Server::Context.new request, response
end

# Use context by instantiating the context without specifying body, output IO::Memory
def context(method : String, route : String, route_params : Hash(String, String)? = nil, headers : Hash(String, String)? = nil, body : JSON::Any? = nil, &block)
  ctx = instantiate_context(method, route, route_params, headers, body)
  yield ctx
  ctx.response.output.rewind

  ctx.response
end

# Helper to instantiate context
def instantiate_context(method : String, route : String, route_params : Hash(String, String)? = nil, headers : Hash(String, String)? = nil, body : JSON::Any? = nil)
  headers_io = HTTP::Headers.new

  if !headers.nil?
    headers.each do |key, value|
      headers_io.add(key, value)
    end
  end

  body_io = body.nil? ? IO::Memory.new : IO::Memory.new(body)
  ctx = context(method, route, headers: headers_io, body: body_io)
  ctx.route_params = route_params unless route_params.nil?
  ctx.response.output = IO::Memory.new

  ctx
end

# Use context by instantiating the context without specifying body, output IO::Memory, instantiating controller in each block
module ActionController::Context
  macro included
    macro inherited
      def self.context(method : String, route : String, route_params : Hash(String, String)? = nil, headers : Hash(String, String)? = nil, body : JSON::Any? = nil, &block)
        ctx = instantiate_context(method, route, route_params, headers, body)
        instance = self.new(ctx)
        yield instance
        ctx.response.output.rewind

        ctx.response
      end
    end
  end
end
