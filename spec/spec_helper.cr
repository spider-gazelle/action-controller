require "kilt"
require "spec"
require "xml"
require "log"
require "../src/action-controller/spec_helper"

Spec.before_suite do
  ::Log.setup "*", :debug, Log::IOBackend.new(formatter: ActionController.default_formatter)
end

class Caching < ActionController::Base
  base "/caching"

  @[AC::Route::GET("/")]
  def index(last_modified : Int64 = Time.utc.to_unix, public : Bool = false) : String?
    last_modified = Time.unix last_modified
    etag = %("12345")

    if stale? last_modified, etag, public
      "response-data"
    end
  end

  # only an etag, no last modified time
  @[AC::Route::GET("/etag")]
  def etag_only : String?
    "etag-data" if stale?(etag: %("abc"))
  end
end

abstract class FilterOrdering < ActionController::Base
  @trusted = false
  @in_around = false

  before_action :set_trust

  def set_trust
    @trusted = true
  end

  @[AC::Route::Filter(:before_action)]
  def check_trust
    render :forbidden, text: "Trust check failed" unless @trusted
  end
end

class SkippingAnnotation < FilterOrdering
  # `base "/skipping_annotation"` configured automatically

  skip_action :set_trust
  skip_action :check_trust

  @[AC::Route::GET("/")]
  def index
    render text: "ok #{@trusted}"
  end
end

class SkippingSymbol < FilterOrdering
  # `base "/skipping_symbol"` configured automatically

  skip_action :set_trust

  @[AC::Route::GET("/")]
  def index
    render text: "ok #{@trusted}"
  end
end

class Filtering < FilterOrdering
  # `base "/filtering"` configured automatically

  add_responder("application/yaml") { |io, result| result.to_yaml(io) }
  add_parser("application/yaml") { |klass, body_io| klass.from_yaml(body_io) }

  add_responder("text/html") { |io, _result, klass, function| "#{klass} == #{function}".to_s(io) }

  @[AC::Route::Filter(:before_action)]
  def confirm_trust(id : String?)
    render :forbidden, text: "Trust confirmation failed" unless @trusted
  end

  @[AC::Route::Filter(:around_action)]
  def wrap_action_here(id : String?, &)
    render :forbidden, text: "Around actions wrap the request" if @trusted
    @in_around = true
    yield
    # perform post checks here
    raise "should be trusted now" unless @trusted
  end

  @[AC::Route::Filter(:around_action)]
  def wrap_next_action_here(id : String?, &)
    render :forbidden, text: "should already be in an around filter" unless @in_around
    yield
    raise "should be trusted now" unless @trusted
  end

  # Ensure that magic methods don't interfere with our annotation routing
  @[AC::Route::GET("/")]
  def index
    render text: "ok"
  end

  @[AC::Route::GET("/:id")]
  def show
    render text: "ok"
  end

  @[AC::Route::GET("/other_route/:id", content_type: "text/plain")]
  def other_route(id : String) : String
    id
  end

  @[AC::Route::GET("/testing/header/values", content_type: "text/plain")]
  def testing_headers(
    @[AC::Param::Info(header: "X-Count", description: "number of requests made", example: "34")]
    value : Int32,
    query_param : Int32,
  ) : String
    "#{value}--#{query_param}"
  end

  @[AC::Route::GET("/testing/header/values/default", content_type: "text/plain")]
  def testing_headers_default(
    query_param : Int32,
    @[AC::Param::Info(header: "X-Count", description: "number of requests made", example: "34")]
    value : Int32 = 12,
  ) : String
    "#{value}--#{query_param}"
  end

  # Test default arguments and multiple routes for a single method
  @[AC::Route::GET("/other_route/:id/test")]
  @[AC::Route::GET("/other_route/test")]
  @[AC::Route::GET("/hex_route/:id", config: {id: {base: 16}})]
  def other_route_test(id : UInt32 = 456_u32, query = "hello") : String
    "#{id}-#{query}"
  end

  enum Colour
    Red
    Green
    Blue
  end

  @[AC::Route::GET("/enum_route/colour/:colour", content_type: "text/plain")]
  @[AC::Route::GET("/enum_route/colour_value/:colour", config: {colour: {from_value: true}}, content_type: "text/plain")]
  def other_route_colour(colour : Colour) : String
    colour.to_s
  end

  # strict: an unparsable colour raises the standard param error instead of
  # being silently ignored (the default for a nilable enum param)
  @[AC::Route::GET("/enum_route/colour_strict", config: {colour: {strict: true}}, content_type: "text/plain")]
  def other_route_colour_strict(colour : Colour? = nil) : String
    colour.to_s
  end

  @[AC::Route::GET("/time_route/:time", config: {time: {format: "%F %:z"}})]
  def other_route_time(time : Time) : Time
    time
  end

  # also tests for optional route params
  @[AC::Route::GET("/multistatus/?:id", status: {Int32 => 201, String => 202})]
  def multistatus_test(id : Int32 | String | Nil)
    id
  end

  @[AC::Route::DELETE("/some_entry/:float", map: {value: :float}, config: {value: {strict: false}}, status_code: HTTP::Status::ACCEPTED, content_type: "json/custom")]
  def delete_entry(value : Float64) : Float64
    value
  end

  @[AC::Route::POST("/some_entry/", status_code: HTTP::Status::ACCEPTED, body: :float)]
  def create_entry(float : Float64 = 300.4) : Float64
    float
  end

  @[AC::Route::POST("/string_entry/", status_code: HTTP::Status::ACCEPTED, body: :string)]
  def create_string_entry(string : String) : String
    string
  end

  @[AC::Route::POST("/some_other_entry/", status_code: HTTP::Status::ACCEPTED)]
  def create_form_encoded_entry(float : Float64) : Float64
    float
  end

  # custom converter
  struct IsHotDog
    def initialize(@strict : Bool = false)
    end

    def convert(raw : String)
      if @strict
        raw == "HotDog"
      else
        raw.downcase == "hotdog"
      end
    end
  end

  @[AC::Route::GET("/what_is_this/:thing", converters: {thing: IsHotDog})]
  @[AC::Route::GET("/what_is_this/:thing/strict", converters: {thing: IsHotDog}, config: {thing: {strict: true}})]
  def other_route_thing(thing : Bool) : Bool
    thing
  end

  @[AC::Route::GET("/param_annotation/:thing")]
  @[AC::Route::GET("/param_annotation/:thing/flexible", config: {thing: {strict: false}})]
  def test_param_annotation(
    @[AC::Param::Converter(class: IsHotDog, config: {strict: true})]
    thing : Bool,
  ) : Bool
    thing
  end

  @[AC::Route::GET("/is_this_bool/")]
  def test_param_name_error(
    @[AC::Param::Info(name: "thing", description: "param name doesn't match variable name", example: "true")]
    is_a_bool : Bool,
  ) : Bool?
    is_a_bool
  end

  # exercises the converters that no other route uses
  @[AC::Route::GET("/converters", content_type: "text/plain")]
  def converter_coverage(
    uuid : UUID,
    letter : Char,
    big : BigInt,
    maybe : UUID? = nil,
  ) : String
    "#{uuid}|#{letter}|#{big}|#{maybe.inspect}"
  end

  # returns the temporary paths backing an upload so a spec can confirm the
  # route entry point cleans them up once the response has been generated
  @[AC::Route::POST("/upload_paths", content_type: "text/plain")]
  def upload_paths : String
    uploads = files
    return "" unless uploads
    uploads.each_value.flat_map(&.each.map(&.file.path)).join("\n")
  end
end

# Testing ID params
class Container < ActionController::Base
  get "/:container_id", :show do
    render text: "got: #{params["container_id"]}"
  end
end

class ContainerObjects < ActionController::Base
  base "/container/:container_id/objects"

  get "/", :index do
    respond_with do
      json do
        data = {"id" => 1}
        data
      end
    end
  end

  get "/:object_id", :show do
    render text: "#{params["object_id"]} in #{params["container_id"]}"
  end
end

class TemplateOne < ActionController::Base
  template_path "./spec/views"
  layout "layout_main.ecr"

  get "/", :index do
    data = client_ip
    if params["inline"]?
      render html: template("inner.ecr")
    else
      render template: "inner.ecr"
    end
  end

  get "/:id", :show do
    data = params["id"]
    if params["inline"]?
      render html: partial("inner.ecr")
    else
      render partial: "inner.ecr"
    end
  end

  post "/params/:yes", :param_check do
    response.headers["Values"] = params.join(" ") { |_, value| value }
    render text: params.join(" ") { |name, _| name }
  end
end

class TemplateTwo < TemplateOne
  layout "layout_alt.ecr"

  get "/", :index do
    data = 50
    render template: "inner.ecr"
  end
end

class BobJane < ActionController::Base
  base "/bob_jane/" # Automatically configured, if excluded, as `base "/bob_jane"`

  before_action :modify_session, only: :modified_session
  add_responder "text/plain" { |io, result| result.to_s(io) }

  get "/", :index do
    session["hello"] = "other_route"
    render text: "index"
  end

  @[AC::Route::GET("/urlencoded", content_type: "application/x-www-form-urlencoded", config: {strict: {name: false}})]
  def urlencoded(name : String) : String
    render text: name
  end

  get "/redirect", :redirect do
    redirect_to "/#{session["hello"]}"
  end

  get "/params/:id", :param_id do
    render text: "params:#{params["id"]}"
  end

  get "/params/:id/test/:test_id", :deep_show do
    render json: {
      id:      params["id"],
      test_id: params["test_id"],
    }
  end

  post "/post_test", :create do
    render :accepted, text: "ok"
  end

  put "/put_test", :update do
    render text: "ok"
  end

  get "/modified_session", :modified_session do
    session["hello"] = "setting_session"
    render text: "ok"
  end

  get "/modified_session_with_redirect", :modified_session_with_redirect do
    session["user_id"] = 42_i64
    redirect_to "/"
  end

  private def modify_session
    session.domain = "bobjane.com"
  end
end

abstract class Application < ActionController::Base
  @[AC::Route::Exception(DivisionByZeroError, status_code: HTTP::Status::BAD_REQUEST, content_type: "text/plain")]
  def confirm_trust(error, id : String?)
    error.message
  end
end

class Users < ActionController::Base
  base "/users"

  get "/", :index do
    head :unauthorized if request.headers["Authorization"]? != "X"

    if params["verbose"] = "true"
      render json: [{name: "James", state: "NSW"}, {name: "Pavel", state: "VIC"}, {name: "Steve", state: "NSW"}, {name: "Gab", state: "QLD"}, {name: "Giraffe", state: "NSW"}]
    else
      render json: ["James", "Pavel", "Steve", "Gab", "Giraffe"]
    end
  end

  get "/test" do
    render text: request.body
  end
end

module ActionController
  annotation TestAnnotation
  end
end

class HelloWorld < Application
  base "/hello"

  force_tls only: [:destroy]

  around_action :around1, only: :around
  around_action :around2, only: :around
  around_action :around2, only: [:show]
  skip_action :around2, only: :show

  before_action :set_var, except: :show
  after_action :after, only: :show

  # raises once the action has already rendered, so the exception handler
  # cannot produce a second response and the error has to continue on
  after_action :raise_after_render, only: :rendered_then_raises

  before_action :render_early, only: :update

  get "/:id", :show do
    raise "set_var was set!" if @me
    res = 42 // params["id"].to_i
    render text: "42 / #{params["id"]} = #{res}"
  end

  get "/rendered/raises", :rendered_then_raises do
    render text: "rendered"
  end

  get "/", :index do
    respond_with do
      text "set_var #{@me}"
      json({set_var: @me})
      xml do
        str = "<set_var>#{@me}</set_var>"
        XML.parse(str)
      end
    end
  end

  get "/annotation/single", :single_annotation, annotations: @[ActionController::TestAnnotation(detail: "single")] do
    render text: {{ @def.annotations(ActionController::TestAnnotation).id.stringify }}
  end

  @[ActionController::TestAnnotation]
  @[ActionController::TestAnnotation]
  get "/annotation/multi", :multi_annotation do
    render text: {{ @def.annotations(ActionController::TestAnnotation).id.stringify }}
  end

  get "/around", :around do
    render text: "var is #{@me}"
  end

  get "/glob/*", :globglob do
    render text: "var is #{params["glob"]}"
  end

  patch "/:id", :update do
    render :accepted, text: "Thanks!"
  end

  private def render_early
    render :forbidden, text: "Access Denied"
  end

  delete "/:id", :destroy do
    head :accepted
  end

  SOCKETS = [] of HTTP::WebSocket
  @[AC::Route::WebSocket("/websocket")]
  def websocket(socket, _id : String?)
    puts "Socket opened"
    SOCKETS << socket

    socket.on_message do |message|
      SOCKETS.each &.send("#{message} + #{@me}")
    end

    socket.on_close do
      puts "Socket closed"
      SOCKETS.delete(socket)
    end
  end

  private def set_var
    me = @me
    me ||= 0
    me += 123
    @me = me
  end

  private def after
    puts "after #{action_name}"
  end

  private def raise_after_render
    42 // 0
  end

  private def around1(&)
    @me = 7
    yield
  end

  private def around2(&)
    me = @me
    me ||= 0
    me += 3
    @me = me
    yield
  end
end

# Manages widgets, used by the MCP specs
#
# widgets are not persisted
class McpWidgets < ActionController::Base
  base "/mcp_widgets"

  # a widget
  struct Widget
    include JSON::Serializable
    include YAML::Serializable

    getter name : String
    getter size : Int32?

    def initialize(@name, @size = nil)
    end
  end

  @[AC::Route::Filter(:before_action)]
  def check_auth
    head :unauthorized unless request.headers["Authorization"]? == "Bearer token"
  end

  # returns the widget requested
  @[AC::Route::GET("/:id")]
  def show(
    id : Int32,
    @[AC::Param::Info(description: "include the widget size", example: "true")]
    detailed : Bool = false,
    @[AC::Param::Info(header: "X-Tenant")]
    tenant : String? = nil,
  ) : Widget
    Widget.new("widget-#{id}-#{tenant}", detailed ? 10 : nil)
  end

  # creates a new widget
  @[AC::Route::POST("/", body: :widget, status_code: HTTP::Status::CREATED)]
  def create(widget : Widget) : Widget
    widget
  end

  # removes a widget
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy(id : Int32) : Nil
  end

  # lists the widget colours
  @[AC::MCP(root: true)]
  @[AC::Route::GET("/colours")]
  def colours : Array(String)
    response.headers["X-Total-Count"] = "2"
    response.headers["Link"] = %(</mcp_widgets/colours?page=2>; rel="next")
    response.cookies << HTTP::Cookie.new("secret", "value")
    ["red", "green"]
  end

  # summarise a widget for the user
  @[AC::MCP(prompt: true)]
  def summarise(
    id : Int32,
    @[AC::Param::Info(description: "the tone of the summary", example: "formal")]
    tone : String = "casual",
  ) : String
    "Summarise widget #{id} in a #{tone} tone"
  end

  # starts a widget review
  @[AC::MCP(prompt: true, root: true)]
  def review(id : Int32) : Array(AC::PromptMessage)
    [
      AC::PromptMessage.user("Review widget #{id}"),
      AC::PromptMessage.assistant("Which aspects should I focus on?"),
    ]
  end

  # not exposed to MCP clients
  @[AC::MCP(hide: true)]
  @[AC::Route::GET("/hidden/secret")]
  def secret : String
    "secret"
  end

  @[AC::Route::WebSocket("/ws")]
  def websocket(socket)
  end
end

# hidden from MCP clients
@[AC::MCP(hide: true)]
class McpHidden < ActionController::Base
  base "/mcp_hidden"

  @[AC::Route::GET("/")]
  def index : String
    "hidden"
  end

  # the only visible route
  @[AC::MCP(hide: false)]
  @[AC::Route::GET("/visible")]
  def visible : String
    "visible"
  end

  @[AC::MCP(prompt: true)]
  def hidden_prompt : String
    "hidden"
  end
end

# read only overrides: searching is read only, touching changes data
@[AC::MCP(read_only: true)]
class McpReadOnly < ActionController::Base
  base "/mcp_read_only"

  # searches widgets
  @[AC::Route::POST("/search", body: :query)]
  def search(query : String) : Array(String)
    ["found #{query}"]
  end

  # records that the widgets were viewed
  @[AC::MCP(read_only: false)]
  @[AC::Route::GET("/touch")]
  def touch : String
    "touched"
  end
end

# served as its own MCP server at /mcp_account/:account_id/mcp
@[AC::MCP(endpoint: true)]
class McpAccount < ActionController::Base
  base "/mcp_account/:account_id"

  # shows a widget in the account
  @[AC::Route::GET("/widgets/:id")]
  def show(account_id : String, id : Int32) : NamedTuple(account: String, id: Int32)
    {account: account_id, id: id}
  end

  # renames the account
  @[AC::Route::POST("/rename", body: :name)]
  def rename(account_id : String, name : String) : String
    "#{account_id} is now #{name}"
  end

  # hidden everywhere
  @[AC::MCP(hide: true)]
  @[AC::Route::GET("/secret")]
  def secret : String
    "secret"
  end

  # describes the account
  @[AC::MCP(prompt: true)]
  def describe(account_id : String, tone : String = "formal") : String
    "Describe account #{account_id} in a #{tone} tone"
  end
end

# served at /mcp_shared/assistant and also by the global server
@[AC::MCP(endpoint: "/assistant", hide: false)]
class McpShared < ActionController::Base
  base "/mcp_shared"

  # replies pong
  @[AC::Route::GET("/ping")]
  def ping : String
    "pong"
  end
end

# MCP Apps cards, see spec/cards. Card and app only tools are root items by default
class McpUi < ActionController::Base
  base "/mcp_ui"

  # shows a booking
  @[AC::MCP(ui: "bookings/card.html")]
  @[AC::Route::GET("/bookings/:id")]
  def show(id : Int32) : NamedTuple(id: Int32, title: String)
    {id: id, title: "Booking #{id}"}
  end

  # checks in to a booking, only the card calls this
  @[AC::MCP(app_only: true)]
  @[AC::Route::POST("/bookings/:id/check_in")]
  def check_in(id : Int32) : NamedTuple(id: Int32, checked_in: Bool)
    {id: id, checked_in: true}
  end

  # lists the rooms
  @[AC::MCP(ui: "ui://rooms/card.html")]
  @[AC::Route::GET("/rooms")]
  def rooms : Array(String)
    ["boardroom"]
  end

  # the booking history, only listed once the toolbox is open
  @[AC::MCP(ui: "bookings/card.html", root: false)]
  @[AC::Route::GET("/bookings/history")]
  def history : Array(Int32)
    [1, 2]
  end
end

# a toolbox with prompts but no tools
class McpPromptsOnly < ActionController::Base
  base "/mcp_prompts_only"

  # suggests a greeting
  @[AC::MCP(prompt: true)]
  def greeting : String
    "Say hello"
  end
end

# everything is available without opening the toolbox
@[AC::MCP(root: true)]
class McpRoot < ActionController::Base
  base "/mcp_root"

  # the current time
  @[AC::Route::GET("/time")]
  def time : String
    "noon"
  end

  # a tiny image
  @[AC::Route::GET("/pixel")]
  def pixel
    response.content_type = "image/png"
    response.headers["ETag"] = %("pixel")
    render binary: String.new(Bytes[137, 80, 78, 71])
  end

  # greets someone
  @[AC::MCP(prompt: true)]
  def greet(name : String) : String
    "Say hello to #{name}"
  end
end

# a generic exception, like `Authly::Error(Code)`
class GenericError(Code) < Exception
  def code : Int32
    Code
  end
end

# handles every instantiation of a generic exception
class GenericErrors < ActionController::Base
  base "/generic_errors"

  @[AC::Route::GET("/:code", content_type: "text/plain")]
  def raise_code(code : Int32) : String
    case code
    when 400 then raise GenericError(400).new("bad request")
    when 401 then raise GenericError(401).new("unauthorized")
    else          "no error"
    end
  end

  @[AC::Route::Exception(GenericError, status_code: HTTP::Status::BAD_REQUEST, content_type: "text/plain")]
  def generic_error(error) : String
    "handled #{error.code}: #{error.message}"
  end
end

# handles one instantiation of a generic exception
class SpecificGenericError < ActionController::Base
  base "/specific_generic_error"

  @[AC::Route::GET("/:code", content_type: "text/plain")]
  def raise_code(code : Int32) : String
    code == 418 ? raise(GenericError(418).new("teapot")) : raise(GenericError(500).new("other"))
  end

  @[AC::Route::Exception(GenericError(418), status_code: HTTP::Status::IM_A_TEAPOT, content_type: "text/plain")]
  def teapot(error) : String
    "short and stout"
  end
end

# every route requires TLS
class ForceTLSEverywhere < ActionController::Base
  base "/force_tls_everywhere"
  force_tls

  @[AC::Route::GET("/", content_type: "text/plain")]
  def index : String
    "secure"
  end
end

# a websocket that requires authentication
class ProtectedSocket < ActionController::Base
  base "/protected_socket"

  @[AC::Route::Filter(:before_action)]
  def check_auth
    head :unauthorized unless request.headers["Authorization"]? == "Bearer token"
  end

  @[AC::Route::WebSocket("/")]
  def echo(socket)
    socket.on_message do |message|
      # the server ends the session
      message == "bye" ? socket.close : socket.send(message)
    end
  end
end

require "../src/action-controller/server"

# require "random"
# Random::Secure.hex

ActionController::Session.configure do |settings|
  settings.key = "_test_session_"
  settings.secret = "4f74c0b358d5bab4000dd3c75465dc2c"
end
