require "./spec_helper"

class KnownLengthController < ActionController::Base
  base "/known_length"

  BODY = "x" * 100_000

  @[AC::Route::GET("/json")]
  def json
    render json: BODY
  end

  @[AC::Route::GET("/text")]
  def text
    render text: BODY
  end

  @[AC::Route::GET("/html")]
  def html
    render html: BODY
  end

  @[AC::Route::GET("/xml")]
  def xml
    render xml: BODY
  end

  @[AC::Route::GET("/yaml")]
  def yaml
    render yaml: BODY
  end

  @[AC::Route::GET("/binary")]
  def binary
    render binary: BODY
  end

  @[AC::Route::GET("/with-prefix")]
  def with_prefix
    response << "prefix:"
    render text: BODY
  end
end

describe ActionController::Responders do
  it "sets the exact byte length for complete large String render bodies" do
    {"json" => "application/json", "text" => "text/plain", "html" => "text/html",
     "xml" => "application/xml", "yaml" => "text/yaml",
     "binary" => "application/octet-stream"}.each do |path, content_type|
      result = ActionController::SpecHelper.client.get("/known_length/#{path}")
      result.status_code.should eq 200
      result.body.should eq KnownLengthController::BODY
      result.headers["Content-Type"].should eq content_type
      result.headers["Content-Length"].should eq KnownLengthController::BODY.bytesize.to_s
      result.headers["Transfer-Encoding"]?.should be_nil
    end
  end

  it "does not add the body length to a HEAD response" do
    result = ActionController::SpecHelper.client.head("/known_length/json")
    result.status_code.should eq 200
    result.body.should be_empty
    result.headers["Content-Length"]?.should_not eq KnownLengthController::BODY.bytesize.to_s
  end

  it "does not declare only the rendered String's length after an earlier body write" do
    result = ActionController::SpecHelper.client.get("/known_length/with-prefix")
    result.status_code.should eq 200
    result.body.should eq "prefix:#{KnownLengthController::BODY}"
    result.headers["Content-Length"]?.should_not eq KnownLengthController::BODY.bytesize.to_s
  end

  it "preserves explicitly selected response framing" do
    body = KnownLengthController::BODY
    response = HTTP::Server::Response.new(IO::Memory.new)
    response.content_length = 123
    ActionController::Responders.write_string(response, body)
    response.headers["Content-Length"].should eq "123"

    response = HTTP::Server::Response.new(IO::Memory.new)
    response.headers["Transfer-Encoding"] = "chunked"
    ActionController::Responders.write_string(response, body)
    response.headers["Content-Length"]?.should be_nil
  end

  it "leaves custom output wrappers and bodyless statuses in control" do
    body = KnownLengthController::BODY
    response = HTTP::Server::Response.new(IO::Memory.new)
    response.output = IO::Memory.new
    ActionController::Responders.write_string(response, body)
    response.headers["Content-Length"]?.should be_nil

    response = HTTP::Server::Response.new(IO::Memory.new)
    response.status = :no_content
    ActionController::Responders.write_string(response, body)
    response.headers["Content-Length"]?.should be_nil
  end
end
