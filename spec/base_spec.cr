require "./spec_helper"

describe ActionController::Base do
  it "should return accepted mime types" do
    c = HelloWorld.controller(accept: "text/html, application/xhtml+xml, application/xml;q=0.9, */*;q=0.8")
    c.accepts_formats.should eq(["text/html", "application/xhtml+xml", "application/xml"])
  end

  it "should return accepted formats" do
    c = HelloWorld.controller(accept: "text/html, application/xhtml+xml, application/xml;q=0.9, */*;q=0.8")
    c.accepts.should eq({
      :html => "text/html",
      :xml  => "application/xml",
    })
  end

  it "should provide helper methods for redirection" do
    HelloWorld.index.should eq("/hello/")
    HelloWorld.show(id: 23).should eq("/hello/23")
    HelloWorld.show({"id" => "23"}).should eq("/hello/23")
  end
end
