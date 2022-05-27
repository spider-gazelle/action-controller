require "../action-controller"
require "hot_topic"

class ActionController::SpecHelper
  include Router

  @route_handler = RouteHandler.new

  def initialize
    init_routes
  end

  private def init_routes
    {% for klass in ActionController::Base::CONCRETE_CONTROLLERS %}
      {{klass}}.__init_routes__(self)
    {% end %}
  end

  def hot_topic
    HotTopic.new(@route_handler)
  end

  def self.client
    ActionController::SpecHelper.new.hot_topic
  end
end
