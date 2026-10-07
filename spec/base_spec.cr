require "./spec_helper"

describe ActionController::Base do
  it "should return accepted mime types" do
    c = HelloWorld.spec_instance(HTTP::Request.new("GET", "/", headers: HTTP::Headers{
      "Accept" => "text/html, application/xhtml+xml, application/xml;q=0.9, */*;q=0.8",
    }))
    c.accepts_formats.should eq(["text/html", "application/xhtml+xml", "application/xml", "*/*"])
  end

  it "should provide a helper for getting the current base route" do
    c = HelloWorld.spec_instance
    c.base_route.should eq("/hello")
    HelloWorld.base_route.should eq("/hello")
  end

  it "should return accepted formats" do
    c = HelloWorld.spec_instance(HTTP::Request.new("GET", "/", headers: HTTP::Headers{
      "Accept" => "text/html, application/xhtml+xml, application/xml;q=0.9, */*;q=0.8",
    }))
    formats = c.accepts_formats
    ActionController::Responders::SelectResponse.accepts(formats).should eq({
      :html => "text/html",
      :xml  => "application/xml",
    })
  end

  it "should provide helper methods for redirection" do
    HelloWorld.index.should eq("/hello/")
    HelloWorld.show(id: 23).should eq("/hello/23")
    HelloWorld.show({"id" => "23"}).should eq("/hello/23")

    HelloWorld.show(
      {"id" => "Weird%!"},
      param1: "woot woot!",
      param2: false
    ).should eq("/hello/Weird%25%21?param1=woot+woot%21&param2=false")
  end

  it "builds paths with optional and glob segments, in the order the router matches them" do
    build = ActionController::Support
    build.build_route("/users/?:user_id/groups").should eq "/users/groups"
    build.build_route("/users/?:user_id/groups", user_id: 5).should eq "/users/groups/5"
    build.build_route("/users/?:user_id/groups", {"user_id" => nil}).should eq "/users/groups"

    # optional segments match cumulatively, a later one without the earlier is a query param
    build.build_route("/x/?:a/?:b", a: 1, b: 2).should eq "/x/1/2"
    build.build_route("/x/?:a/?:b", b: 2).should eq "/x?b=2"

    # a glob keeps its slashes
    build.build_route("/files/:id/*:path", id: 1, path: "docs/read me.md").should eq "/files/1/docs/read%20me.md"
    build.build_route("/files/:id/*:path", id: 1).should eq "/files/1"

    # segments are replaced whole, and a value can't add a segment
    build.build_route("/items/:id/:id_two", id: 1, id_two: 2).should eq "/items/1/2"
    build.build_route("/items/:id", id: "a/b").should eq "/items/a%2Fb"
  end

  it "should raise a BadRoute error if a route param is missing" do
    expect_raises(ActionController::InvalidRoute, "route parameters missing :id") do
      HelloWorld.show
    end
  end

  it "should execute filters in the order they were defined" do
    client = AC::SpecHelper.client

    result = client.get("/filtering")
    result.body.should eq("ok")

    result = client.get("/filtering/other_route/the_id")
    result.body.should eq "the_id"
  end

  describe "route annotations" do
    client = AC::SpecHelper.client

    it "can be a single annotation" do
      client.get("/hello/annotation/single").body.should eq %([@[ActionController::TestAnnotation(detail: "single")]])
    end

    it "can be an array of annotations" do
      client.get("/hello/annotation/multi").body.should eq %([@[ActionController::TestAnnotation], @[ActionController::TestAnnotation]])
    end
  end
end
