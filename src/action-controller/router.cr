require "./router/server_context"
require "./router/route_handler"

# :nodoc:
module ActionController::Router
  alias Action = (HTTP::Server::Context, Bool) -> HTTP::Server::Context
  HTTP_METHODS = %w(get post put patch delete options head)

  getter route_handler : RouteHandler = ::ActionController::Router::RouteHandler.new

  # Define each method for supported http actions
  {% for http_method in HTTP_METHODS %}
    def {{http_method.id}}(path : String, &block : Action)
      @route_handler.add_route({{http_method.id.upcase.stringify}}, path, {block, false})
      {% if http_method == "get" %}
        @route_handler.add_route("HEAD", path, {block, true})
      {% end %}
    end
  {% end %}
end
