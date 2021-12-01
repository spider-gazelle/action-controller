require "lucky_router"

class ActionController::Router::RouteHandler
  include HTTP::Handler

  def initialize
    @matcher = LuckyRouter::Matcher(Tuple(Action, Bool)).new
    @static_routes = {} of String => Tuple(Action, Bool)
  end

  # Builds the internal representation of a route
  # then searches static routes before checking the matcher
  def search_route(context : HTTP::Server::Context) : Tuple(Action, Bool)?
    search_path = "#{context.request.method}#{context.request.path}"
    action = @static_routes.fetch(search_path) do
      match = @matcher.match(context.request.method, context.request.path)
      if match
        context.route_params = match.params
        match.payload
      end
    end
    action
  end

  # Routes requests to the appropriate handler
  # Called from HTTP::Server in server.cr
  def call(context : HTTP::Server::Context)
    if action = search_route(context)
      # Set the controller name
      ::Log.context.set(controller_method: action[1])
      action[0].call(context, action[1])
    else
      # defined in https://crystal-lang.org/api/latest/HTTP/Handler.html
      call_next(context)
    end
  end

  # Adds a route handler to the system
  # Determines if routes are static or require decomposition and stores them appropriately
  def add_route(method : String, path : String, action : Tuple(Action, Bool))
    @matcher.add(method, path, action)

    unless path.includes?(':') || path.includes?('*')
      lookup_key = "#{method}#{path}"
      @static_routes[lookup_key] = action

      # Add static routes with both trailing and non-trailing / chars
      if lookup_key.ends_with? '/'
        @static_routes[lookup_key[0..-2]] = action
      else
        @static_routes["#{lookup_key}/"] = action
      end
    end
  end
end
