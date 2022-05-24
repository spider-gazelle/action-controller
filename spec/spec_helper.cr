require "kilt"
require "spec"
require "xml"
require "log"
require "./curl_context"
require "../src/action-controller"

Spec.before_suite do
  ::Log.setup "*", :debug, Log::IOBackend.new(formatter: ActionController.default_formatter)
end

abstract class FilterOrdering < ActionController::Base
  @trusted = false

  before_action :set_trust
  before_action :check_trust

  def set_trust
    @trusted = true
  end

  def check_trust
    render :forbidden, text: "Trust check failed" unless @trusted
  end
end

class FilterCheck < FilterOrdering
  base "/filtering"
  before_action :confirm_trust

  @[Route::GET("/")]
  def index
    render text: "ok"
  end

  @[Route::GET("/other_route/:id")]
  def other_route(id : String) : String
    id
  end

  @[Route::GET("/other_route/:id/test")]
  def other_route_test(id : String = "456") : String
    id
  end

  def confirm_trust
    render :forbidden, text: "Trust confirmation failed" unless @trusted
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
  # base "/bob/jane" # <== automatically configured
  before_action :modify_session, only: :modified_session

  # Test default CRUD
  def index
    session["hello"] = "other_route"
    render text: "index"
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
  rescue_from DivisionByZeroError do |error|
    render :bad_request, text: error.message
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
  ws "/websocket", :websocket do |socket|
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
