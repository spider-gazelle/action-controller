require "./spec_helper"

describe AC::Route::Builder do
  client = AC::SpecHelper.client

  it "should work with shared routes" do
    result = client.get("/filtering/other_route/1234/test?query=bye")
    result.body.should eq("1234-bye")

    result = client.get("/filtering/other_route/test")
    result.body.should eq "456-hello"
  end

  it "should work with custom param config" do
    result = client.get("/filtering/hex_route/ABCD")
    result.body.should eq "43981-hello"
  end

  it "should work with enums" do
    result = client.get("/filtering/enum_route/colour/RED")
    result.body.should eq "Red"

    result = client.get("/filtering/enum_route/colour_value/1")
    result.body.should eq "Green"
  end

  it "should work with custom time formats" do
    result = client.get("/filtering/time_route/2016-04-05%20%2B00%3A00")
    result.body.should eq "\"2016-04-05T00:00:00+00:00\""
  end

  it "should return custom status codes and content types" do
    result = client.delete("/filtering/some_entry/4.56-not-strict")
    result.body.should eq "4.56"
    result.status_code.should eq 202
    result.headers["Content-Type"].should eq "json/custom"
  end

  it "should work with custom converters" do
    result = client.get("/filtering/what_is_this/hotdog")
    result.body.should eq "true"

    result = client.get("/filtering/what_is_this/NotHotDog")
    result.body.should eq "false"

    result = client.get("/filtering/what_is_this/hotdog/strict")
    result.body.should eq "false"

    result = client.get("/filtering/what_is_this/HotDog/strict")
    result.body.should eq "true"
  end
end
