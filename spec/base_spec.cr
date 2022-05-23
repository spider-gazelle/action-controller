require "./spec_helper"

describe ActionController::Base do
  it "should return accepted mime types" do
    c = HelloWorld.new(context("GET", "/", accept: "text/html, application/xhtml+xml, application/xml;q=0.9, */*;q=0.8"))
    c.accepts_formats.should eq(["text/html", "application/xhtml+xml", "application/xml"])
  end

  it "should provide a helper for getting the current base route" do
    c = HelloWorld.new(context("GET", "/"))
    c.base_route.should eq("/hello")
    HelloWorld.base_route.should eq("/hello")
  end

  it "should return accepted formats" do
    c = HelloWorld.new(context("GET", "/", accept: "text/html, application/xhtml+xml, application/xml;q=0.9, */*;q=0.8"))
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

  it "should raise a BadRoute error if a route param is missing" do
    expect_raises(ActionController::InvalidRoute, "route parameters missing :id") do
      HelloWorld.show
    end
  end

  it "should execute filters in the order they were defined" do
    result = curl("GET", "/filtering")
    result.body.should eq("ok")

    result = curl("GET", "/filtering/other_route/the_id")
    result.body.should eq(%("the_id"))
  end

  describe "route annotations" do
    it "can be a single annotation" do
      curl("GET", "/hello/annotation/single").body.should eq %([@[ActionController::TestAnnotation(detail: "single")]])
    end

    it "can be an array of annotations" do
      curl("GET", "/hello/annotation/multi").body.should eq %([@[ActionController::TestAnnotation], @[ActionController::TestAnnotation]])
    end
  end
end
