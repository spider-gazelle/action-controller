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

# Creates a context for specing controllers
def context(method : String, path : String, headers : HTTP::Headers? = nil, body : String | Bytes | IO | Nil = nil, version = "HTTP/1.1", **header_opts)
  headers ||= HTTP::Headers.new
  header_opts.each do |key, value|
    headers.add(key.to_s.split(/-|_/).map(&.capitalize).join("-"), value.to_s)
  end
  response = HTTP::Server::Response.new(IO::Memory.new, version)
  request = HTTP::Request.new(method, path, headers, body, version)
  HTTP::Server::Context.new request, response
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
