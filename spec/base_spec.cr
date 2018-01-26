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
end
