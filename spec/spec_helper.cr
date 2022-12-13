require "kilt"
require "spec"
require "xml"
require "log"
require "../src/action-controller/spec_helper"

Spec.before_suite do
  ::Log.setup "*", :debug, Log::IOBackend.new(formatter: ActionController.default_formatter)
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
  def wrap_action_here(id : String?)
    render :forbidden, text: "Around actions wrap the request" if @trusted
    @in_around = true
    yield
    # perform post checks here
    raise "should be trusted now" unless @trusted
  end

  @[AC::Route::Filter(:around_action)]
  def wrap_next_action_here(id : String?)
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

  @[AC::Route::GET("/time_route/:time", config: {time: {format: "%F %:z"}})]
  def other_route_time(time : Time) : Time
    time
  end

  @[AC::Route::GET("/multistatus/:id", status: {Int32 => 201, String => 202})]
  def multistatus_test(id : Int32 | String)
    id
  end

  @[AC::Route::DELETE("/some_entry/:float", map: {value: :float}, config: {value: {strict: false}}, status_code: HTTP::Status::ACCEPTED, content_type: "json/custom")]
  def delete_entry(value : Float64) : Float64
    value
  end

  @[AC::Route::POST("/some_entry/", status_code: HTTP::Status::ACCEPTED, body: :float)]
  def create_entry(float : Float64) : Float64
    float
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
    thing : Bool
  ) : Bool
    thing
  end
end

# Testing ID params
class Container < ActionController::Base
  id_param :container_id

  def show
    render text: "got: #{params["container_id"]}"
  end
end

class ContainerObjects < ActionController::Base
  base "/container/:container_id/objects"
  id_param :object_id

  def index
    respond_with do
      json do
        data = {"id" => 1}
        data
      end
    end
  end

  def show
    render text: "#{params["object_id"]} in #{params["container_id"]}"
  end
end

class TemplateOne < ActionController::Base
  template_path "./spec/views"
  layout "layout_main.ecr"

  def index
    data = client_ip # ameba:disable Lint/UselessAssign
    if params["inline"]?
      render html: template("inner.ecr")
    else
      render template: "inner.ecr"
    end
  end

  def show
    data = params["id"] # ameba:disable Lint/UselessAssign
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

  def index
    data = 50 # ameba:disable Lint/UselessAssign
    render template: "inner.ecr"
  end
end

class BobJane < ActionController::Base
  base "/bob_jane/" # Automatically configured, if excluded, as `base "/bob_jane"`

  before_action :modify_session, only: :modified_session
  add_responder "text/plain" { |io, result| result.to_s(io) }

  # Test default CRUD
  def index
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

  def index
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

  before_action :render_early, only: :update

  def show
    raise "set_var was set!" if @me
    res = 42 // params["id"].to_i
    render text: "42 / #{params["id"]} = #{res}"
  end

  def index
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

  def update
    render :accepted, text: "Thanks!"
  end

  private def render_early
    render :forbidden, text: "Access Denied"
  end

  def destroy
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

  private def around1
    @me = 7
    yield
  end

  private def around2
    me = @me
    me ||= 0
    me += 3
    @me = me
    yield
  end
end

require "../src/action-controller/server"

# require "random"
# Random::Secure.hex

ActionController::Session.configure do |settings|
  settings.key = "_test_session_"
  settings.secret = "4f74c0b358d5bab4000dd3c75465dc2c"
end
