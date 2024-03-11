require "./spec_helper"

describe ActionController::Base do
  it "should return 304 when using If-Modified-Since headers" do
    client = AC::SpecHelper.client

    last_modified = 5.minutes.ago
    result = client.get("/caching?last_modified=#{last_modified.to_unix}", headers: HTTP::Headers{
      "If-Modified-Since" => HTTP.format_time(last_modified),
    })
    result.status_code.should eq 304
    result.body.should eq ""
    result.headers["Last-Modified"]?.should eq HTTP.format_time(last_modified)

    result = client.get("/caching?last_modified=#{last_modified.to_unix}", headers: HTTP::Headers{
      "If-Modified-Since" => HTTP.format_time(4.minutes.ago),
    })
    result.status_code.should eq 304
    result.body.should eq ""
    result.headers["Last-Modified"]?.should eq HTTP.format_time(last_modified)

    result = client.get("/caching?last_modified=#{last_modified.to_unix}", headers: HTTP::Headers{
      "If-Modified-Since" => HTTP.format_time(6.minutes.ago),
    })
    result.status_code.should eq 200
    result.body.should eq %("response-data")
    result.headers["Last-Modified"]?.should eq HTTP.format_time(last_modified)
  end

  it "should return 304 when using If-None-Match headers" do
    client = AC::SpecHelper.client
    result = client.get("/caching", headers: HTTP::Headers{
      "If-None-Match" => %("12345"),
    })
    result.status_code.should eq 304
    result.body.should eq ""
    result.headers["ETag"]?.should eq %("12345")

    result = client.get("/caching", headers: HTTP::Headers{
      "If-None-Match" => "*",
    })
    result.status_code.should eq 304
    result.body.should eq ""
    result.headers["ETag"]?.should eq %("12345")

    result = client.get("/caching", headers: HTTP::Headers{
      "If-None-Match" => %("11111", "12345"),
    })
    result.status_code.should eq 304
    result.body.should eq ""
    result.headers["ETag"]?.should eq %("12345")

    result = client.get("/caching", headers: HTTP::Headers{
      "If-None-Match" => %("11111"),
    })
    result.status_code.should eq 200
    result.body.should eq %("response-data")
    result.headers["ETag"]?.should eq %("12345")
  end

  it "should return 304 when using If-Modified-Since and If-None-Match headers" do
    client = AC::SpecHelper.client

    last_modified = 5.minutes.ago
    result = client.get("/caching?last_modified=#{last_modified.to_unix}", headers: HTTP::Headers{
      "If-Modified-Since" => HTTP.format_time(last_modified),
      "If-None-Match"     => %("12345"),
    })
    result.status_code.should eq 304
    result.body.should eq ""
    result.headers["Last-Modified"]?.should eq HTTP.format_time(last_modified)
    result.headers["ETag"]?.should eq %("12345")

    result = client.get("/caching?last_modified=#{last_modified.to_unix}", headers: HTTP::Headers{
      "If-Modified-Since" => HTTP.format_time(last_modified),
      "If-None-Match"     => %("11111"),
    })
    result.status_code.should eq 200
    result.body.should eq %("response-data")
    result.headers["Last-Modified"]?.should eq HTTP.format_time(last_modified)
    result.headers["ETag"]?.should eq %("12345")

    result = client.get("/caching?last_modified=#{last_modified.to_unix}", headers: HTTP::Headers{
      "If-Modified-Since" => HTTP.format_time(6.minutes.ago),
      "If-None-Match"     => %("12345"),
    })
    result.status_code.should eq 200
    result.body.should eq %("response-data")
    result.headers["Last-Modified"]?.should eq HTTP.format_time(last_modified)
    result.headers["ETag"]?.should eq %("12345")
  end
end
