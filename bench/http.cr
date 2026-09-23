# Run with: crystal build --release -o /tmp/ac-http-bench bench/http.cr
# Then: /tmp/ac-http-bench action-controller 3000
#       /tmp/ac-http-bench bare 3000
require "../src/action-controller"
require "../src/action-controller/server"

class BenchController < ActionController::Base
  base "/"

  @[AC::Route::GET("/plain")]
  def plain
    render text: "OK"
  end

  @[AC::Route::GET("/user/:id")]
  def user(id : String)
    render text: id
  end

  @[AC::Route::GET("/json")]
  def json
    {message: "Hello, world!"}
  end

  @[AC::Route::GET("/json-buffered")]
  def json_buffered
    render json: {message: "Hello, world!"}.to_json
  end
end

mode = ARGV[0]? || "action-controller"
port = (ARGV[1]?.try(&.to_i) || 3000)

case mode
when "action-controller"
  ActionController::Server.new(port: port, host: "127.0.0.1").run
when "bare"
  server = HTTP::Server.new do |context|
    path = context.request.path
    if path == "/plain"
      context.response.content_type = "text/plain"
      context.response.print "OK"
    elsif path.starts_with?("/user/") && (id = path.byte_slice(6)).size > 0 && !id.includes?('/')
      context.response.content_type = "text/plain"
      context.response.print id
    elsif path == "/json"
      context.response.content_type = "application/json"
      {message: "Hello, world!"}.to_json(context.response)
    elsif path == "/json-buffered"
      context.response.content_type = "application/json"
      context.response.print({message: "Hello, world!"}.to_json)
    else
      context.response.status_code = 404
    end
  end
  server.bind_tcp "127.0.0.1", port
  server.listen
else
  abort "expected action-controller or bare"
end
