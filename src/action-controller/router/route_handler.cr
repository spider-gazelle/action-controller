require "lucky_router"

# :nodoc:
class ActionController::Router::RouteHandler
  include HTTP::Handler

  def initialize
    @matcher = LuckyRouter::Matcher(Tuple(Action, Bool)).new
    # keyed on {method, path} rather than a concatenation of the two so that
    # lookups don't have to build a string on every request
    @static_routes = {} of Tuple(String, String) => Tuple(Action, Bool)
  end

  # Searches static routes before checking the matcher
  def search_route(method, req_path, context : HTTP::Server::Context) : Tuple(Action, Bool)?
    @static_routes.fetch({method, req_path}) do
      if match = @matcher.match(method, req_path)
        context.route_params = match.params
        match.payload
      end
    end
  end

  # Routes requests to the appropriate handler
  # Called from HTTP::Server in server.cr
  def call(context : HTTP::Server::Context)
    method = context.request.method
    req_path = context.request.path

    if action = search_route(method, req_path, context)
      process_request(method, req_path, context, action[0], action[1])
    else
      # defined in https://crystal-lang.org/api/latest/HTTP/Handler.html
      call_next(context)
    end
  end

  # We split out the processing of the request for simplified injection of telemetry
  def process_request(method, req_path, context, controller_dispatch, head_request)
    controller_dispatch.call(context, head_request)
  end

  # Adds a route handler to the system
  # Determines if routes are static or require decomposition and stores them appropriately
  def add_route(method : String, path : String, action : Tuple(Action, Bool))
    @matcher.add(method, path, action)

    unless path.includes?(':') || path.includes?('*')
      @static_routes[{method, path}] = action

      # Add static routes with both trailing and non-trailing / chars
      if path.ends_with? '/'
        @static_routes[{method, path.rchop}] = action
      else
        @static_routes[{method, "#{path}/"}] = action
      end
    end
  end
end
