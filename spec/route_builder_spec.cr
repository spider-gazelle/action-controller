require "./spec_helper"

describe Route::Builder do
  it "should work with shared routes" do
    result = curl("GET", "/filtering/other_route/1234/test?query=bye")
    result.body.should eq("1234-bye")

    result = curl("GET", "/filtering/other_route/test")
    result.body.should eq "456-hello"
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
end
