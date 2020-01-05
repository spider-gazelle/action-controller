require "delimiter_tree"

class ActionController::Router::RouteHandler
  include HTTP::Handler

  def initialize
    @tree = Delimiter::Tree(Tuple(Action, Bool)).new
    @static_routes = {} of String => Tuple(Action, Bool)
  end

  # Builds the internal representation of a route
  # then searches static routes before checking the radix tree
  def search_route(context : HTTP::Server::Context) : Tuple(Action, Bool)?
    search_path = "/#{context.request.method}#{context.request.path}"
    action = @static_routes.fetch(search_path) do
      route = @tree.find(search_path)
      if route.found?
        context.route_params = route.params
        route.payload.last
      end
    end
    action
  end

  # Routes requests to the appropriate handler
  # Called from HTTP::Server in server.cr
  def call(context : HTTP::Server::Context)
    if action = search_route(context)
      action[0].call(context, action[1])
    else
      # defined in https://crystal-lang.org/api/latest/HTTP/Handler.html
      call_next(context)
    end
  end

  # Adds a route handler to the system
  # Determines if routes are static or require decomposition and stores them appropriately
  def add_route(key : String, action : Tuple(Action, Bool))
    @tree.add(key, action)

    unless key.includes?(':') || key.includes?('*')
      @static_routes[key] = action

      # Add static routes with both trailing and non-trailing / chars
      if key.ends_with? '/'
        @static_routes[key[0..-2]] = action
      else
        @static_routes[key + "/"] = action
      end
    end
  end
end
