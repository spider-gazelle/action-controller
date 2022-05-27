require "../action-controller"
require "hot_topic"

module ActionController
  class SpecHelper
    include Router

    getter route_handler = RouteHandler.new

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

    module ContextHelper
      macro included
        macro inherited
          def self.spec_instance(request : HTTP::Request = HTTP::Request.new("GET", "/"))
            response = HTTP::Server::Response.new(IO::Memory.new, request.version)
            context = HTTP::Server::Context.new request, response
            context.response.output = IO::Memory.new

            method = request.method
            req_path = request.path
            search_path = "#{method}#{req_path}"

            ActionController::SpecHelper.new.route_handler.search_route(method, req_path, search_path, context)
            self.new(context)
          end
        end
      end
    end
  end

  # extend the action controller classes with the `with_state` helper
  abstract class Base
    include SpecHelper::ContextHelper
  end
end
