# Spider-Gazelle Action Controller

[![CI](https://github.com/spider-gazelle/action-controller/actions/workflows/ci.yml/badge.svg)](https://github.com/spider-gazelle/action-controller/actions/workflows/ci.yml)

Extending [lucky_router](https://github.com/luckyframework/lucky_router) for a Rails like DSL without the overhead. See the [docs site](https://spider-gazelle.net/) for usage details

## Strong Parameter Usage

```crystal
require "action-controller"

# Abstract classes don't generate routes
abstract class Application < ActionController::Base
  # A filter can raise or render to prevent a route being executed
  @[AC::Route::Filter(:before_action)]
  def ensure_authenticated
    render :unauthorized unless cookies["user"]
  end

  # You can define controller level exception handlers for consistent error messages
  # note, the first param is always the error object
  @[AC::Route::Exception(Route::Param::Error, status_code: :not_found)]
  def route_param_error(error, id : Int64?)
    # as id is nillable, it will look for a supplied id (route, query, formdata)
    # and set it if one was found and it could be converted
    {
      error: error.message,
      parameter: error.parameter,
      restriction: error.restriction
    }
  end
end

# Full inheritance support (concrete classes generate routes)
class Books < Application
  # this is automatically configured based on class name and namespace
  # it can be overriden here
  base "/books"

  # route => "/books/?book=1234"
  @[Route::GET("/")]
  def index(book : UInt64? = nil) : Array(String)
    redirect_to Books.show(id: book) if book
    ["book1", "book2"]
  end

  # Params are automatically extracted and converted to the corrent type
  # here `id` in the route matches the `id` paramater in the function
  # route => "/books/0FF/hex"
  # route => "/books/123"
  @[Route::GET("/:id/hex", config: {id: {base: 16}})]
  @[Route::GET("/:id")]
  def show(id : UInt64)
    {id: id, name: "book1"}
  end

  enum Color
    Red
    Blue
    Green
  end

  # route => "/books/set_color/RED"
  # route => "/books/set_color/colour_value/2"
  @[Route::GET("/set_color/:colour")]
  @[Route::GET("/set_color/colour_value/:colour", config: {colour: {from_value: true}})]
  def set_color(color : Color) : String
    colour.to_s
  end

  # Websocket support, the first param is always the socket object
  # route => "/books/:id/realtime"
  @[AC::Route::WebSocket("/:id/realtime")]
  def realtime(socket, id : UInt64)
    SOCKETS << socket

    socket.on_message do |message|
      SOCKETS.each { |socket| socket.send "Echo back from server: #{message}" }
    end

    socket.on_close do
      SOCKETS.delete(socket)
    end
  end

  SOCKETS = [] of HTTP::WebSocket
end
```

* For more details on usage, see [the documentation](https://spider-gazelle.net/).
* Also see [detailed project documentation](https://spider-gazelle.github.io/action-controller/ActionController.html)
