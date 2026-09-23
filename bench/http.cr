# Run with: crystal build --release -o /tmp/ac-http-bench bench/http.cr
# Then: /tmp/ac-http-bench action-controller 3000
#       /tmp/ac-http-bench bare 3000
require "../src/action-controller"
require "../src/action-controller/server"

LARGE_JSON_DATA = "x" * 100_000
LARGE_JSON_BODY = %({"data":"#{LARGE_JSON_DATA}"})
SMALL_JSON_BODY = %({"message":"Hello, world!"})

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

  @[AC::Route::GET("/json-static")]
  def json_static
    render json: SMALL_JSON_BODY
  end

  @[AC::Route::GET("/json-buffered")]
  def json_buffered
    render json: {message: "Hello, world!"}.to_json
  end

  @[AC::Route::GET("/json-large")]
  def json_large
    {data: LARGE_JSON_DATA}
  end

  @[AC::Route::GET("/json-large-buffered")]
  def json_large_buffered
    render json: {data: LARGE_JSON_DATA}.to_json
  end

  @[AC::Route::GET("/json-large-static")]
  def json_large_static
    render json: LARGE_JSON_BODY
  end

  @[AC::Route::GET("/json-large-static-length")]
  def json_large_static_length
    response.content_length = LARGE_JSON_BODY.bytesize
    render json: LARGE_JSON_BODY
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
    elsif path == "/json-static"
      context.response.content_type = "application/json"
      context.response.print SMALL_JSON_BODY
    elsif path == "/json-buffered"
      context.response.content_type = "application/json"
      context.response.print({message: "Hello, world!"}.to_json)
    elsif path == "/json-large"
      context.response.content_type = "application/json"
      {data: LARGE_JSON_DATA}.to_json(context.response)
    elsif path == "/json-large-buffered"
      context.response.content_type = "application/json"
      context.response.print({data: LARGE_JSON_DATA}.to_json)
    elsif path == "/json-large-static"
      context.response.content_type = "application/json"
      context.response.print LARGE_JSON_BODY
    elsif path == "/json-large-static-length"
      context.response.content_type = "application/json"
      context.response.content_length = LARGE_JSON_BODY.bytesize
      context.response.print LARGE_JSON_BODY
    else
      context.response.status_code = 404
    end
  end
  server.bind_tcp "127.0.0.1", port
  server.listen
else
  abort "expected action-controller or bare"
end
