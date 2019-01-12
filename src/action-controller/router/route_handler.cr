require "radix"

class ActionController::Router::RouteHandler
  include HTTP::Handler

  def initialize
    @tree = Radix::Tree(Action).new
    @static_routes = {} of String => Action
  end

  def search_route(context : HTTP::Server::Context) : Action?
    search_path = "/#{context.request.method}#{context.request.path}"
    action = @static_routes.fetch(search_path) do
      route = @tree.find(search_path)
      if route.found?
        context.route_params = route.params
        route.payload
      end
    end
    action
  end

  def call(context : HTTP::Server::Context)
    if action = search_route(context)
      action.call(context)
    else
      call_next(context)
    end
  end

  def add_route(key : String, action : Action)
    if key.includes?(':') || key.includes?('*')
      @tree.add(key, action)
    else
      @static_routes[key] = action
      if key.ends_with? '/'
        @static_routes[key[0..-2]] = action
      else
        @static_routes[key + "/"] = action
      end
    end
  end
end
