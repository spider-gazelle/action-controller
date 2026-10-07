require "./spec_helper"
require "../src/action-controller/server"

module ComposableFirst
  abstract class Base < AC::Base
  end

  class Pages < Base
    base "/composition/first"

    before_action :mark

    def mark
      response.headers["X-App"] = "first"
    end

    @[AC::Route::GET("/")]
    def index : String
      "first"
    end

    @[AC::Route::GET("/missing")]
    def missing
      render :not_found, text: "deliberate"
    end
  end
end

module ComposableSecond
  abstract class Base < AC::Base
  end

  class Pages < Base
    base "/composition/second"

    @[AC::Route::GET("/")]
    def index : String
      "second"
    end
  end
end

private class CompositionFallback
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    context.response.print "fallback"
  end
end

class CompositionOAuth < AC::Base
  base "/composition/oauth"

  @[AC::Route::GET("/token")]
  def token : String
    request.path
  end

  @[AC::Route::GET("/redirect")]
  def redirect
    redirect_to token_path
  end
end

class CompositionHost < AC::Base
  base "/composition/host/"
  mount "/auth/", CompositionOAuth
  mount "/backup/", CompositionOAuth
end

class CompositionOuter < AC::Base
  base "/composition/outer"
  mount "/inner/", CompositionHost
end

class CompositionCycleA < AC::Base
  mount "/b", CompositionCycleB
  mount "/conflicts", CompositionConflicts::Base
end

class CompositionCycleB < AC::Base
  mount "/a", CompositionCycleA
end

module CompositionConflicts
  abstract class Base < AC::Base
  end

  class First < Base
    base "/composition/conflict"
    @[AC::Route::GET("/:id")]
    def show(id : String) : String
      id
    end
  end

  class Second < Base
    base "/composition/conflict"
    @[AC::Route::GET("/:name")]
    def show(name : String) : String
      name
    end
  end
end

describe AC::Composition do
  it "serves only descendants of an abstract application base" do
    handler = ComposableFirst::Base.handler
    client = HotTopic.new(handler)
    client.get("/composition/first").body.should eq %q("first")
    client.get("/composition/second").status_code.should eq 404
    handler.routes.map(&.[0]).uniq.should eq ["ComposableFirst::Pages"]
  end

  it "passes route misses through independent handlers" do
    first = ComposableFirst::Base.handler
    second = ComposableSecond::Base.handler
    first.next = second
    second.next = CompositionFallback.new
    client = HotTopic.new(first)
    client.get("/composition/second").body.should eq %q("second")
    client.get("/unknown").body.should eq "fallback"
    client.get("/composition/second").headers.has_key?("X-App").should be_false
  end

  it "keeps responses from matched actions even when they return 404" do
    handler = ComposableFirst::Base.handler
    handler.next = CompositionFallback.new
    response = HotTopic.new(handler).get("/composition/first/missing")
    response.status_code.should eq 404
    response.body.should eq "deliberate"
    response.headers["X-App"].should eq "first"
  end

  it "constructs independent routers and handler chains" do
    first = ComposableFirst::Base.handler
    second = ComposableFirst::Base.handler
    first.next = CompositionFallback.new
    second.next.should be_nil
    first.route_handler.should_not be second.route_handler
    HotTopic.new(first.handler).get("/unknown").status_code.should eq 404
  end

  it "supports HTTP::Server's normal handler typing" do
    handlers = [ComposableFirst::Base.handler, CompositionFallback.new] of HTTP::Handler
    server = HTTP::Server.new(handlers)
    server.close
  end

  it "shares explicit selection with the server and spec helper" do
    previous = AC::Composition.default
    begin
      composition = AC::Composition.new([ComposableFirst::Base.name, ComposableSecond::Base.name])
      AC::Composition.default = composition
      AC::Server.routes.map(&.[0]).should eq ["ComposableFirst::Pages", "ComposableFirst::Pages", "ComposableSecond::Pages"]
      server = AC::Server.new(composition: composition)
      server.composition.should be composition
      server.route_handler.should_not be composition.route_handler
      AC::SpecHelper.new(composition).hot_topic.get("/composition/second").status_code.should eq 200
      AC::SpecHelper.new(composition).hot_topic.get("/hello").status_code.should eq 404
      server.close
    ensure
      AC::Composition.default = previous
    end
  end

  it "mounts replacement bases repeatedly without exposing the original path" do
    client = HotTopic.new(CompositionHost.handler)
    client.get("/composition/host/auth/token").body.should eq %q("/composition/host/auth/token")
    client.get("/composition/host/backup/token").status_code.should eq 200
    client.get("/composition/oauth/token").status_code.should eq 404
    CompositionOAuth.token.should eq "/composition/oauth/token"
    client.get("/composition/host/auth/redirect").headers["Location"].should eq "/composition/host/auth/token"
  end

  it "expands nested mounts and passes their route misses downstream" do
    handler = CompositionOuter.handler
    handler.next = CompositionFallback.new
    client = HotTopic.new(handler)
    client.get("/composition/outer/inner/auth/token").status_code.should eq 200
    client.get("/composition/outer/inner/auth/missing").body.should eq "fallback"
  end

  it "rejects cycles and equivalent parameterized public routes" do
    expect_raises(ArgumentError, /mount cycle/) { CompositionCycleA.handler }
    expect_raises(ArgumentError, /conflicting route GET/) { CompositionConflicts::Base.handler }
    expect_raises(ArgumentError, /unknown application root/) { AC::Composition.new(["MissingApplication"]) }
  end
end
