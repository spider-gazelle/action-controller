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

  # The paths a route matches, with every segment kept where it's written. Optional (`?:`)
  # segments are added one after another: `/a/?:b/c/?:d` is `/a/c`, `/a/:b/c` and
  # `/a/:b/c/:d`. With `glob: true` a trailing glob (`*:`) is optional too.
  #
  # Each path comes with the name of the first optional segment it leaves out, `nil` for the
  # full path.
  def self.optional_variants(path : String, glob : Bool = false) : Array(Tuple(String, String?))
    parts = path.split('/')
    optional = parts.each_index.select { |index| parts[index].starts_with?("?:") || (glob && parts[index].starts_with?("*:")) }.to_a

    (0..optional.size).map do |count|
      left_out = optional[count..]
      variant = parts.each_with_index.compact_map do |(part, index)|
        next if left_out.includes?(index)
        part.starts_with?("?:") ? part.lchop('?') : part
      end.join('/')
      {variant.presence || "/", left_out.first?.try { |index| parts[index].split(':', 2)[1] }}
    end
  end

  # Adds a route handler to the system
  # Optional segments are expanded so they match where they're written (lucky_router would
  # move them after the required segments)
  def add_route(method : String, path : String, action : Tuple(Action, Bool))
    self.class.optional_variants(path).each { |(variant, _)| add_path(method, variant, action) }
  end

  # Determines if routes are static or require decomposition and stores them appropriately
  private def add_path(method : String, path : String, action : Tuple(Action, Bool))
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
