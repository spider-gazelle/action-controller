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

  it "should reject unparsable enum values when strict" do
    # valid values and an absent param behave as normal for a nilable param
    result = client.get("/filtering/enum_route/colour_strict?colour=RED")
    result.body.should eq "Red"

    result = client.get("/filtering/enum_route/colour_strict?colour=1")
    result.body.should eq "Green"

    result = client.get("/filtering/enum_route/colour_strict")
    result.body.should eq ""

    # without `strict: true` this would silently resolve to nil
    error = expect_raises(AC::Route::Param::ValueError, "invalid parameter value for 'colour'") do
      client.get("/filtering/enum_route/colour_strict?colour=cyan")
    end
    error.parameter.should eq "colour"
    error.restriction.should_not be_nil
    error.restriction.try(&.includes?("Colour")).should be_true
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

  it "should handle custom param names" do
    result = client.get("/filtering/is_this_bool?thing=true")
    result.body.should eq "true"

    result = client.get("/filtering/is_this_bool?thing=false")
    result.body.should eq "false"

    # a Bool is coerced rather than rejected -- anything that isn't "true" is false
    result = client.get("/filtering/is_this_bool?thing=whatever")
    result.body.should eq "false"

    # ensure expected errors are raised
    # (expect_raises rather than begin/rescue so the example fails if no error
    # is raised at all, and so the message is checked -- it is built by a shared
    # helper rather than inline in each route)
    missing = expect_raises(AC::Route::Param::MissingError, "missing required parameter 'thing'") do
      client.get("/filtering/is_this_bool")
    end
    missing.parameter.should eq "thing"
    missing.restriction.should eq "Bool"
  end

  it "should work with a body param" do
    result = client.post("/filtering/some_entry", body: "34.5")
    result.body.should eq %(34.5)

    result = client.post("/filtering/some_entry", headers: HTTP::Headers{
      "Content-Type" => "application/json",
    }, body: "34.6")
    result.body.should eq %(34.6)

    result = client.post("/filtering/some_entry", headers: HTTP::Headers{
      "Content-Type" => "application/json; charset=utf-8",
    }, body: "34.7")
    result.body.should eq %(34.7)

    # check support for default body values
    result = client.post("/filtering/some_entry")
    result.body.should eq %(300.4)
  end

  it "String bodies should work with text/plain mime" do
    result = client.post("/filtering/string_entry", headers: HTTP::Headers{
      "Content-Type" => "text/plain",
    }, body: "some text")
    result.body.should eq %("some text")

    expect_raises(JSON::ParseException) do
      client.post("/filtering/string_entry", body: "some text")
    end
  end

  it "should work with other charsets" do
    body_text = "34.8".encode("UTF-16")
    body_text.bytesize.should eq 10
    result = client.post("/filtering/some_entry", headers: HTTP::Headers{
      "Content-Type" => "application/json; charset=UTF-16",
    }, body: body_text)
    result.body.should eq %(34.8)

    result = client.post("/filtering/some_entry", headers: HTTP::Headers{
      "Content-Type" => "application/json; charset=us-ascii",
    }, body: "34.7")
    result.body.should eq %(34.7)
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

  it "should work with optional route params" do
    result = client.get("/filtering/multistatus/")
    result.status_code.should eq 200
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

    # a type we can actually render wins over an earlier wildcard
    headers = HTTP::Headers{
      "Accept" => "*/*, application/yaml",
    }
    result = client.get("/filtering/other_route/4/test", headers: headers)
    result.status_code.should eq 200
    result.content_type.should eq "application/yaml"
  end

  it "where no body is expected, accept application/x-www-form-urlencoded data as params" do
    headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
    body = "float=3.14"
    result = client.post("/filtering/some_other_entry/", headers: headers, body: body)
    result.body.should eq("3.14")
  end

  it "should skip filters as expected" do
    result = client.get("/skipping_symbol")
    result.status_code.should eq 403

    result = client.get("/skipping_annotation")
    result.status_code.should eq 200
  end

  it "should parse headers as params" do
    result = client.get("/filtering/testing/header/values?query_param=12", headers: HTTP::Headers{
      "X-Count" => "123",
    })
    result.status_code.should eq 200
    result.body.should eq "123--12"

    result = client.get("/filtering/testing/header/values/default?query_param=13")
    result.status_code.should eq 200
    result.body.should eq "12--13"

    # test error handling
    expect_raises(ActionController::Route::Param::MissingError, "missing required header 'X-Count'") do
      client.get("/filtering/testing/header/values?query_param=12")
    end

    expect_raises(ActionController::Route::Param::ValueError, "invalid header value for 'X-Count'") do
      client.get("/filtering/testing/header/values?query_param=12", headers: HTTP::Headers{
        "X-Count" => "abc",
      })
    end

    expect_raises(ActionController::Route::Param::ValueError, "invalid header value for 'X-Count'") do
      client.get("/filtering/testing/header/values/default?query_param=12", headers: HTTP::Headers{
        "X-Count" => "abc",
      })
    end

    # the query parameter equivalents of the above, which take a separate path
    # through the builder to the same shared error helper
    invalid = expect_raises(ActionController::Route::Param::ValueError, "invalid parameter value for 'query_param'") do
      client.get("/filtering/testing/header/values/default?query_param=abc")
    end
    invalid.parameter.should eq "query_param"
    invalid.restriction.should eq "Int32"

    missing = expect_raises(ActionController::Route::Param::MissingError, "missing required parameter 'query_param'") do
      client.get("/filtering/testing/header/values/default")
    end
    missing.parameter.should eq "query_param"
    missing.restriction.should eq "Int32"
  end

  it "should work with globs" do
    result = client.get("/hello/glob/value")
    result.status_code.should eq 200
    result.body.should eq "var is value"
  end
end

describe "uploaded file cleanup" do
  client = AC::SpecHelper.client

  it "deletes temporary upload files once the route has completed" do
    headers = HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=AaB03x"}
    body = <<-BODY
      --AaB03x
      Content-Disposition: form-data; name="files"; filename="file1.txt"
      Content-Type: text/plain

      ... contents of file1.txt ...
      --AaB03x--
      BODY
    body = body.gsub("\n", "\r\n")

    result = client.post("/filtering/upload_paths", headers: headers, body: body)
    result.status_code.should eq 200

    paths = result.body.split("\n").reject(&.empty?)
    paths.size.should eq 1

    # the route entry point calls __cleanup_uploads__ after responding, so the
    # temporary file the parser wrote must be gone by now
    paths.each do |path|
      File.exists?(path).should be_false
    end
  end
end

describe "converters without other coverage" do
  client = AC::SpecHelper.client
  uuid = "b8d0f0c0-1f1a-4b3c-9d2e-5a6f7c8d9e0f"

  it "converts UUID, Char and BigInt params" do
    result = client.get("/filtering/converters?uuid=#{uuid}&letter=abc&big=123456789012345678901234567890")
    result.status_code.should eq 200
    # Char takes the first character, the optional UUID stays nil
    result.body.should eq "#{uuid}|a|123456789012345678901234567890|nil"
  end

  it "populates an optional UUID when supplied" do
    result = client.get("/filtering/converters?uuid=#{uuid}&letter=z&big=1&maybe=#{uuid}")
    result.body.should eq "#{uuid}|z|1|UUID(#{uuid})"
  end

  it "rejects an unparsable UUID" do
    error = expect_raises(AC::Route::Param::ValueError, "invalid parameter value for 'uuid'") do
      client.get("/filtering/converters?uuid=not-a-uuid&letter=a&big=1")
    end
    error.restriction.should eq "UUID"
  end

  it "rejects an empty Char" do
    expect_raises(AC::Route::Param::ValueError, "invalid parameter value for 'letter'") do
      client.get("/filtering/converters?uuid=#{uuid}&letter=&big=1")
    end
  end

  it "raises out of the converter for an unparsable BigInt" do
    # ConvertBigInt uses to_big_i, which raises rather than returning nil, so
    # this surfaces as ArgumentError instead of a Param::ValueError
    expect_raises(ArgumentError) do
      client.get("/filtering/converters?uuid=#{uuid}&letter=a&big=nope")
    end
  end
end

describe "Accept header parsing" do
  # accepts_formats is hand rolled for speed, so pin its exact output --
  # including the quirk that only a comma consumes the whitespace after it
  formats_for = ->(accept : String?) do
    headers = HTTP::Headers.new
    headers["Accept"] = accept if accept
    Filtering.spec_instance(HTTP::Request.new("GET", "/filtering/", headers)).accepts_formats
  end

  it "extracts the mime types a client will accept" do
    formats_for.call("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,*/*;q=0.8")
      .should eq ["text/html", "application/xhtml+xml", "application/xml", "image/avif", "*/*"]
  end

  it "handles a single type, a wildcard and a missing header" do
    formats_for.call("application/json").should eq ["application/json"]
    formats_for.call("*/*").should eq ["*/*"]
    formats_for.call("").should eq [] of String
    formats_for.call(nil).should eq [] of String
  end

  it "drops q-values and consumes whitespace after a comma" do
    formats_for.call("text/html; q=0.9,application/json").should eq ["text/html", "application/json"]
    formats_for.call("application/json,   text/plain").should eq ["application/json", "text/plain"]
  end

  it "leaves whitespace around a semicolon alone" do
    # only `,` consumed trailing whitespace in the original regex based
    # implementation, so a type following `;` keeps its leading whitespace
    formats_for.call("a/b ;q=1").should eq ["a/b "]
    formats_for.call("text/html; application/json").should eq ["text/html", " application/json"]
    formats_for.call("a/b;  c/d").should eq ["a/b", "  c/d"]
    formats_for.call("text/html;\tapplication/xml").should eq ["text/html", "\tapplication/xml"]
  end
end

describe "repeated query params" do
  client = AC::SpecHelper.client

  it "reads an array from every repetition of the name, converting each element" do
    client.get("/filtering/repeated?tag=a&tag=b").body.should eq %(["a", "b"]|nil|[])
    client.get("/filtering/repeated?count=1&count=2&kind=fresh&kind=stale").body.should eq %([]|[1, 2]|[Filtering::Flavour::Fresh, Filtering::Flavour::Stale])
    client.get("/filtering/repeated?tag=one").body.should eq %(["one"]|nil|[])
  end

  it "falls back to the default, or nil, when the name is absent" do
    client.get("/filtering/repeated").body.should eq %([]|nil|[])
  end

  it "rejects an element that does not convert, naming its index and value" do
    error = expect_raises(AC::Route::Param::ValueError, %(invalid parameter value for 'count' at index 1: "x")) do
      client.get("/filtering/repeated?count=1&count=x")
    end
    error.parameter.should eq "count"
    error.restriction.should eq "(Array(Int32) | Nil)"
    expect_raises(AC::Route::Param::ValueError, %(invalid parameter value for 'kind' at index 1: "rotten")) do
      client.get("/filtering/repeated?kind=fresh&kind=rotten")
    end
  end

  it "requires an array with no default" do
    expect_raises(AC::Route::Param::MissingError, "missing required parameter 'id'") do
      client.get("/filtering/repeated/set")
    end
  end

  it "reads a Set, collapsing repetitions" do
    client.get("/filtering/repeated/set?id=1&id=1").body.should eq %([1, 1]|Set{}|nil)
    client.get("/filtering/repeated/set?id=2&tag=a&tag=b&tag=a&kind=fresh&kind=fresh").body.should eq %([2]|Set{"a", "b"}|Set{Filtering::Flavour::Fresh})
    expect_raises(AC::Route::Param::ValueError, %(invalid parameter value for 'kind' at index 0: "rotten")) do
      client.get("/filtering/repeated/set?id=1&kind=rotten")
    end
  end

  it "reads repetitions from a form body, applying converter config to each element" do
    headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
    result = client.post("/filtering/repeated/form", headers: headers, body: "tag=a&tag=b&level=1&level=0&flag=yes&flag=no")
    result.body.should eq %(["a", "b"]|[Filtering::Flavour::Stale, Filtering::Flavour::Fresh]|[true, false])
    expect_raises(AC::Route::Param::ValueError, %(invalid parameter value for 'level' at index 0: "7")) do
      client.post("/filtering/repeated/form", headers: headers, body: "tag=a&level=7")
    end
  end
end

describe "request bodies a route consumes" do
  client = AC::SpecHelper.client
  typed = ->(type : String) { HTTP::Headers{"Content-Type" => type} }

  it "binds a raw body as it is, in the types the route consumes" do
    client.post("/filtering/upload", headers: typed.call("image/png"), body: "png!").body.should eq "4 bytes of image/png"
    error = expect_raises(AC::Route::UnsupportedMediaType) do
      client.post("/filtering/upload", headers: typed.call("application/json"), body: "{}")
    end
    error.accepts.should eq ["application/pdf", "image/png"]
    expect_raises(AC::Route::UnsupportedMediaType) { client.post("/filtering/upload", body: "no type") }
  end

  it "binds a raw body of any type when the route does not say what it consumes" do
    client.post("/filtering/stream", headers: typed.call("text/csv"), body: "a,b").body.should eq "A,B"
  end

  it "parses only the types the route consumes" do
    client.post("/filtering/json_only", headers: typed.call("application/json"), body: "1.5").body.should eq "1.5"
    error = expect_raises(AC::Route::UnsupportedMediaType) do
      client.post("/filtering/json_only", headers: typed.call("application/yaml"), body: "1.5")
    end
    error.accepts.should eq ["application/json"]
  end
end
