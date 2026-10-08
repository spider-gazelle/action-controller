require "../src/action-controller"

# Build with -Dlucky_router_only to compare sending every request through
# LuckyRouter. This alternative intentionally allocates params on static hits;
# production retains AC's static binding semantics and allocation-free lookup.
{% if flag?(:lucky_router_only) %}
  class ActionController::Router::RouteHandler
    # Keep LuckyRouter's own index enabled for the all-LuckyRouter alternative.
    private def compiled_matcher : LuckyRouter::CompiledMatcher(Tuple(Action, Bool))
      if snapshot = @compiled_matcher.get(:acquire)
        return snapshot
      end
      @compile_lock.synchronize do
        snapshot = @compiled_matcher.get(:acquire)
        unless snapshot
          snapshot = @matcher.compile
          @compiled_matcher.set(snapshot, :release)
        end
        snapshot
      end
    end

    def search_route(method, req_path, context : HTTP::Server::Context) : Tuple(Action, Bool)?
      if match = match_route(method, req_path)
        context.route_params = match.params
        match.payload
      end
    end
  end
{% end %}
