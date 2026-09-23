require "./spec_helper"

private class JSONBufferCountingIO < IO
  getter writes = 0
  getter data = IO::Memory.new
  getter write_sizes = [] of Int32

  def read(slice : Bytes) : Int32
    raise IO::Error.new("write-only")
  end

  def write(slice : Bytes) : Nil
    @writes += 1
    @write_sizes << slice.size
    @data.write(slice)
  end
end

private struct ResponseOnlyJSON
  def to_json(output : HTTP::Server::Response) : Nil
    output << %({"response_only":true})
  end

  def to_yaml(output : HTTP::Server::Response) : Nil
    output << "response_only: true"
  end
end

class JSONBufferCustomController < ActionController::Base
  base "/json_buffer_custom"

  @json_evaluations = 0

  @[AC::Route::GET("/")]
  def index
    render json: ResponseOnlyJSON.new
  end

  @[AC::Route::GET("/generated")]
  def generated
    ResponseOnlyJSON.new
  end

  @[AC::Route::GET("/once")]
  def once
    render json: next_json
  end

  private def next_json
    @json_evaluations += 1
    %({"evaluations":#{@json_evaluations}})
  end
end

describe ActionController::JSONBuffer do
  it "combines small serializer writes without changing bytes" do
    output = JSONBufferCountingIO.new
    ActionController::JSONBuffer.serialize(output, {message: "hello"})
    output.data.to_s.should eq %({"message":"hello"})
    output.write_sizes.should eq [output.data.size]
  end

  it "keeps exact output while growing past its inline capacity" do
    [127, 128, 129, 512, ActionController::JSONBuffer::LIMIT].each do |size|
      value = {data: "x" * size}
      output = JSONBufferCountingIO.new
      ActionController::JSONBuffer.serialize(output, value)
      output.data.to_s.should eq value.to_json
    end
  end

  it "passes large responses through after the bounded buffer fills" do
    output = JSONBufferCountingIO.new
    large_value = "x" * (ActionController::JSONBuffer::LIMIT + 1)
    ActionController::JSONBuffer.write(output) do |buffer|
      buffer << "["
      large_value.to_json(buffer)
      buffer << "]"
    end
    output.data.to_s.should eq "[#{large_value.to_json}]"
    output.writes.should be > 1
  end

  it "preserves bytes written before a serializer raises" do
    output = JSONBufferCountingIO.new
    expect_raises(ArgumentError, "failed") do
      ActionController::JSONBuffer.write(output) do |buffer|
        buffer << %({"partial":)
        raise ArgumentError.new("failed")
      end
    end
    output.data.to_s.should eq %({"partial":)
  end

  it "keeps the concrete response type for custom serializers" do
    bytes = IO::Memory.new
    response = HTTP::Server::Response.new(bytes)
    ActionController::JSONBuffer.serialize(response, ResponseOnlyJSON.new)
    response.close
    bytes.to_s.should contain %({"response_only":true})
  end

  it "lets the native response close small JSON with a known length" do
    bytes = IO::Memory.new
    response = HTTP::Server::Response.new(bytes)
    ActionController::JSONBuffer.serialize(response, {message: "hello"})
    response.close
    wire = bytes.to_s
    wire.should contain "Content-Length: 19\r\n"
    wire.should_not contain "Transfer-Encoding: chunked"
    wire.ends_with?(%({"message":"hello"})).should be_true
  end

  it "keeps bounded writes when the HTTP output is wrapped" do
    response = HTTP::Server::Response.new(IO::Memory.new)
    wrapper = JSONBufferCountingIO.new
    response.output = wrapper
    ActionController::JSONBuffer.serialize(response, {message: "hello"})
    wrapper.data.to_s.should eq %({"message":"hello"})
    wrapper.writes.should eq 1
  end

  it "keeps response-specialized serializers working in explicit render" do
    result = ActionController::SpecHelper.client.get("/json_buffer_custom")
    result.status_code.should eq 200
    result.body.should eq %({"response_only":true})
  end

  it "keeps response-specialized serializers working in generated responses" do
    result = ActionController::SpecHelper.client.get("/json_buffer_custom/generated")
    result.status_code.should eq 200
    result.body.should eq %({"response_only":true})
  end

  it "evaluates an explicit JSON render expression once" do
    result = ActionController::SpecHelper.client.get("/json_buffer_custom/once")
    result.status_code.should eq 200
    result.body.should eq %({"evaluations":1})
  end
end
