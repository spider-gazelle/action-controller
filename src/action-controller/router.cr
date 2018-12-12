require "./router/server_context"
require "./router/route_handler"

module ActionController::Router
  alias Action = HTTP::Server::Context -> HTTP::Server::Context
  HTTP_METHODS = %w(get post put patch delete options)

  getter route_handler : RouteHandler = ::ActionController::Router::RouteHandler.new

  # Define each method for supported http methods
  {% for http_method in HTTP_METHODS %}
    def {{http_method.id}}(path : String, &block : Action)
      @route_handler.add_route("/{{http_method.id.upcase}}" + path, block)
    end
  {% end %}
end
