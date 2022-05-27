require "./spec_helper"

describe AC::Route::Builder do
  client = AC::SpecHelper.client

  it "should work with shared routes" do
    response = client.get("/filtering/other_route/1234/test?query=bye")
    response.body.should eq("1234-bye")

    response = client.get("/filtering/other_route/test")
    response.body.should eq "456-hello"
  end

  it "should work with custom param config" do
    result = curl("GET", "/filtering/hex_route/ABCD")
    result.body.should eq "43981-hello"
  end

  it "should work with enums" do
    result = curl("GET", "/filtering/enum_route/colour/RED")
    result.body.should eq "Red"

    result = curl("GET", "/filtering/enum_route/colour_value/1")
    result.body.should eq "Green"
  end

  it "should work with custom time formats" do
    result = curl("GET", "/filtering/time_route/2016-04-05%20%2B00%3A00")
    result.body.should eq "\"2016-04-05T00:00:00+00:00\""
  end

  it "should return custom status codes and content types" do
    result = curl("DELETE", "/filtering/some_entry/4.56-not-strict")
    result.body.should eq "4.56"
    result.status_code.should eq 202
    result.headers["Content-Type"].should eq "json/custom"
  end

  it "can spec via direct instansiation" do
    # Instantiate the controller
    body_io = IO::Memory.new
    ctx = context("GET", BASE, body: body_io, authorization: "X")
    ctx.route_params = {"verbose" => "true"}
    ctx.response.output = IO::Memory.new

    testable_controller = FilterCheck.new(ctx)
    testable_controller.other_route("some_input").should eq "some_input"
  end

  it "should work with custom converters" do
    result = curl("GET", "/filtering/what_is_this/hotdog")
    result.body.should eq "true"

    result = curl("GET", "/filtering/what_is_this/NotHotDog")
    result.body.should eq "false"

    result = curl("GET", "/filtering/what_is_this/hotdog/strict")
    result.body.should eq "false"

    result = curl("GET", "/filtering/what_is_this/HotDog/strict")
    result.body.should eq "true"
  end
end
