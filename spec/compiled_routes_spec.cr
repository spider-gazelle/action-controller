require "./spec_helper"

{% if LuckyRouter::Matcher(Int32).has_method?(:compile) %}
  private def compiled_context(path : String)
    HTTP::Server::Context.new(HTTP::Request.new("GET", path), HTTP::Server::Response.new(IO::Memory.new))
  end

  private def compiled_action(name : String)
    ->(context : HTTP::Server::Context, _head : Bool) {
      context.response.headers["X-Route"] = name
      context
    }
  end

  private class CompiledLifecycleRouter
    include AC::Router
  end

  describe "compiled routing" do
    it "prepares routes once and invalidates after additions" do
      handler = AC::Router::RouteHandler.new
      handler.add_route("GET", "/compiled/:id", {compiled_action("original"), false})
      handler.compiled?.should be_false
      handler.compile_routes
      handler.compile_routes
      handler.compiled?.should be_true
      context = compiled_context("/compiled/7")
      action = handler.search_route("GET", "/compiled/7", context).should_not be_nil
      action[0].call(context, false)
      context.response.headers["X-Route"].should eq "original"
      context.route_params.should eq({"id" => "7"})

      handler.add_route("GET", "/late/:id", {compiled_action("late"), false})
      handler.compiled?.should be_false
      context = compiled_context("/late/9")
      action = handler.search_route("GET", "/late/9", context).should_not be_nil
      action[0].call(context, false)
      context.route_params.should eq({"id" => "9"})
      context.response.headers["X-Route"].should eq "late"
      handler.compiled?.should be_true
    end

    {% if flag?(:preview_mt) %}
      it "publishes a complete lazy snapshot to concurrent readers" do
        handler = AC::Router::RouteHandler.new
        handler.add_route("GET", "/parallel/:id", {compiled_action("parallel"), false})
        results = Channel(String?).new(8)
        threads = Array.new(8) do |index|
          Thread.new do
            error = nil
            100.times do |number|
              value = "#{index}-#{number}"
              path = "/parallel/#{value}"
              context = compiled_context(path)
              unless handler.search_route("GET", path, context) && context.route_params == {"id" => value}
                error = "incorrect match for #{path}"
              end
            end
            results.send(error)
          rescue ex
            results.send(ex.message || "concurrent lookup failed")
          end
        end
        8.times { results.receive.should be_nil }
        threads.each(&.join)
        handler.compiled?.should be_true
      end
    {% end %}

    it "rebuilds a snapshot after a failed registration" do
      handler = AC::Router::RouteHandler.new
      handler.add_route("GET", "/compiled/:id", {compiled_action("original"), false})
      handler.compile_routes
      expect_raises(LuckyRouter::DuplicateRouteError) do
        handler.add_route("GET", "/compiled/:other", {compiled_action("duplicate"), false})
      end
      handler.compiled?.should be_false
      context = compiled_context("/compiled/7")
      action = handler.search_route("GET", "/compiled/7", context).should_not be_nil
      action[0].call(context, false)
      context.response.headers["X-Route"].should eq "original"
      context.route_params.should eq({"id" => "7"})
    end

    it "preserves upstream bindings on misses and isolates matched static routes" do
      handler = AC::Router::RouteHandler.new
      handler.isolate_path_params = true
      handler.add_route("GET", "/fixed", {compiled_action("fixed"), false})
      handler.add_route("GET", "/dynamic/:id", {compiled_action("dynamic"), false})
      handler.compile_routes
      context = compiled_context("/")
      upstream = {"id" => "upstream"}
      context.route_params = upstream
      handler.search_route("GET", "/missing", context).should be_nil
      context.route_params.same?(upstream).should be_true
      handler.search_route("GET", "/dynamic/7", context).should_not be_nil
      context.route_params.should eq({"id" => "7"})
      handler.search_route("GET", "/fixed", context).should_not be_nil
      context.route_params.should be_empty
      upstream.should eq({"id" => "upstream"})
    end

    it "serves compiled optional, glob, encoded, HEAD and deep routes" do
      router = CompiledLifecycleRouter.new
      router.get("/optional/?:id") { |context, _head| context }
      router.get("/files/*:rest") { |context, _head| context }
      router.get("/space/a b") { |context, _head| context }
      router.get("/deep/#{(1..20).map { |i| ":p#{i}" }.join('/')}") { |context, _head| context }
      router.compile_routes
      handler = router.route_handler
      {
        "/optional"       => {} of String => String,
        "/optional/7"     => {"id" => "7"},
        "/files/a%2Fb/c/" => {"rest" => "a/b/c"},
        "/files"          => {} of String => String,
        "/space/a%20b"    => {} of String => String,
      }.each do |path, params|
        context = compiled_context(path)
        handler.search_route("GET", path, context).should_not be_nil
        context.route_params.should eq params
      end
      path = "/deep/#{(1..20).join('/')}"
      context = compiled_context(path)
      action = handler.search_route("HEAD", path, context).should_not be_nil
      action[1].should be_true
      context.route_params.should eq((1..20).to_h { |i| {"p#{i}", i.to_s} })
    end
  end

  describe AC::Server do
    it "compiles before listening when run has no callback" do
      server = AC::Server.new(0)
      begin
        server.get("/compiled-startup") do |context, _|
          context.response.print(server.route_handler.compiled?.to_s)
          context
        end
        server.socket.bind_tcp("127.0.0.1", 0)
        port = server.socket.addresses.first.as(Socket::IPAddress).port
        spawn { server.run }
        HTTP::Client.get("http://127.0.0.1:#{port}/compiled-startup").body.should eq "true"
      ensure
        server.close
      end
    end

    it "compiles routes registered in the binding callback before listening" do
      server = AC::Server.new(0)
      begin
        bound = Channel(Bool).new
        spawn do
          server.run do
            prepared = server.route_handler.compiled?
            server.get("/compiled-callback") do |context, _|
              context.response.print(server.route_handler.compiled?.to_s)
              context
            end
            bound.send(prepared)
          end
        end
        bound.receive.should be_true
        port = server.socket.addresses.first.as(Socket::IPAddress).port
        HTTP::Client.get("http://127.0.0.1:#{port}/compiled-callback").body.should eq "true"
      ensure
        server.close
      end
    end
  end
{% end %}
