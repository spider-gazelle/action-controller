# each flag declares a parameter the route builder rejects at compile time
require "../../src/action-controller"

class CollectionParams < AC::Base
  base "/collections"

  {% if flag?(:path_param) %}
    @[AC::Route::GET("/:tag")]
    def index(tag : Array(String)) : Nil
    end
  {% elsif flag?(:optional_path_param) %}
    @[AC::Route::GET("/?:tag")]
    def index(tag : Array(String)? = nil) : Nil
    end
  {% elsif flag?(:header_param) %}
    @[AC::Route::GET("/")]
    def index(
      @[AC::Param::Info(header: "X-Tags")]
      tag : Array(String),
    ) : Nil
    end
  {% elsif flag?(:io_subclass_body) %}
    @[AC::Route::POST("/", body: :file)]
    def index(file : IO::Memory) : Nil
    end
  {% elsif flag?(:nested_param) %}
    @[AC::Route::GET("/")]
    def index(tag : Array(Set(String))) : Nil
    end
  {% end %}
end
