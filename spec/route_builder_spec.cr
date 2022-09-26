require "./spec_helper"

describe AC::Route::Builder do
  client = AC::SpecHelper.client

  it "should work with shared routes" do
    headers = HTTP::Headers{
      "Accept" => "text/plain",
    }

    result = client.get("/filtering/other_route/1234/test?query=bye", headers: headers)
    result.body.should eq("1234-bye")

    result = client.get("/filtering/other_route/test", headers: headers)
    result.body.should eq "456-hello"
  end

  it "should work with custom param config" do
    result = client.get("/filtering/hex_route/ABCD")
    result.body.should eq %("43981-hello")
  end

  it "should work with enums" do
    result = client.get("/filtering/enum_route/colour/RED")
    result.body.should eq "Red"

    result = client.get("/filtering/enum_route/colour/1")
    result.body.should eq "Green"

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

  it "should work with param converter annotations" do
    result = client.get("/filtering/param_annotation/HotDog")
    result.body.should eq "true"

    result = client.get("/filtering/param_annotation/hotdog")
    result.body.should eq "false"

    result = client.get("/filtering/param_annotation/NotHotDog")
    result.body.should eq "false"

    result = client.get("/filtering/param_annotation/hotdog/flexible")
    result.body.should eq "true"

    result = client.get("/filtering/param_annotation/HotDog/flexible")
    result.body.should eq "true"
  end

  it "should work with a body param" do
    result = client.post("/filtering/some_entry", body: "34.5")
    result.body.should eq %(34.5)
  end

  it "should pass the klass and function name to responders" do
    result = client.post("/filtering/some_entry", body: "34.5", headers: HTTP::Headers{
      "Accept" => "text/html",
    })
    result.body.should eq %(filtering == create_entry)
  end

  it "should work with different status types" do
    result = client.get("/filtering/multistatus/45")
    result.status_code.should eq 201

    result = client.get("/filtering/multistatus/hello")
    result.status_code.should eq 202
  end

  it "should work with custom accepts types" do
    headers = HTTP::Headers{
      "Accept" => "*/*",
    }
    result = client.get("/filtering/other_route/1/test", headers: headers)
    result.status_code.should eq 200
    result.content_type.should eq "application/json"
    result.body.should eq %("1-hello")

    headers = HTTP::Headers{
      "Accept" => "application/xhtml+xml, application/xml;q=0.9, */*;q=0.8",
    }
    result = client.get("/filtering/other_route/2/test", headers: headers)
    result.status_code.should eq 200
    result.content_type.should eq "application/json"

    headers = HTTP::Headers{
      "Accept" => "application/xhtml+xml, application/yaml;q=0.9, */*;q=0.8",
    }
    result = client.get("/filtering/other_route/3/test", headers: headers)
    result.status_code.should eq 200
    result.content_type.should eq "application/yaml"
  end
end
