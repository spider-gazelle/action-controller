require "./spec_helper"

describe "end to end requests and responses" do
  mock_server = MockServer.new(3000)

  spawn do
    mock_server.run
  end

  sleep 0.5

  it "#index" do
    result = curl("GET", "/bob_jane/")
    result.not_nil!.body.should eq("index")
  end

  it "creates and works with session data" do
    result = curl("GET", "/bob_jane/")
    result.not_nil!.body.should eq("index")
    cookie = result.not_nil!.headers["Set-Cookie"]
    cookie.starts_with?("_test_session_=").should eq(true)

    cookie = cookie.split("%3B")[0]
    result = curl("GET", "/bob_jane/redirect", {"Cookie" => cookie})
    result.not_nil!.headers["Location"].should eq("/other_route")
  end

  it "#redirect" do
    cookie = "_test_session_=CKQMLS12oJZBIh3Hlbpg19XGFAphCiRW7NMHq31epbpGTfI9N0T7WeIR1C%2FFDJ%2FW--IEb0qAXKV9DtrLdnyqzdGbBM2ww%3D"
    result = curl("GET", "/bob_jane/redirect", {"Cookie" => cookie})
    result.not_nil!.headers["Location"].should eq("/other_route")
  end

  it "#params" do
    result = curl("GET", "/bob_jane/params/1")
    result.not_nil!.body.should eq("params:1")
    result = curl("GET", "/bob_jane/params/2")
    result.not_nil!.body.should eq("params:2")
  end

  it "#test_param" do
    result = curl("GET", "/bob_jane/params/1/test/3")
    result.not_nil!.status_code.should eq(200)
    result.not_nil!.body.should eq("{\"id\":\"1\",\"test_id\":\"3\"}")
    result = curl("GET", "/bob_jane/params/2/test/4")
    result.not_nil!.body.should eq("{\"id\":\"2\",\"test_id\":\"4\"}")
  end

  it "#post_test" do
    result = curl("POST", "/bob_jane/post_test/")
    result.not_nil!.body.should eq("ok")
    result.not_nil!.status_code.should eq(202)
  end

  it "#put_test" do
    result = curl("PUT", "/bob_jane/put_test/")
    result.not_nil!.body.should eq("ok")
  end

  it "#unknown_path" do
    result = curl("GET", "/bob_jane/unknown_path")
    result.not_nil!.status_code.should eq(404)
  end

  it "should work with inheritance" do
    result = curl("GET", "/hello/2")
    result.not_nil!.status_code.should eq(200)
    result.not_nil!.body.should eq("42 / 2 = 21")
  end

  it "should prioritise route params" do
    result = curl("GET", "/hello/2?id=7")
    result.not_nil!.status_code.should eq(200)
    result.not_nil!.body.should eq("42 / 2 = 21")
  end

  it "should rescue errors as required" do
    result = curl("GET", "/hello/0")
    result.not_nil!.body.should eq("Division by zero")
    result.not_nil!.status_code.should eq(400)
  end

  it "should perform before actions and execute the action" do
    result = curl("GET", "/hello/")
    result.not_nil!.body.should eq("set_var 123")
    result.not_nil!.status_code.should eq(200)
  end

  it "should select the appropriate response type" do
    result = curl("GET", "/hello/", {"Accept" => "text/yaml, application/json, text/plain"})
    result.not_nil!.body.should eq("{\"set_var\":123}")
    result.not_nil!.status_code.should eq(200)

    result = curl("GET", "/hello/", {"Accept" => "text/yaml"})
    result.not_nil!.body.should eq("")
    result.not_nil!.status_code.should eq(406)

    result = curl("GET", "/hello/", {"Accept" => "text/xml"})
    result.not_nil!.body.should eq("<?xml version=\"1.0\"?>\n<set_var>123</set_var>\n")
    result.not_nil!.status_code.should eq(200)
  end

  it "should stop callbacks if render is called in a before filter" do
    result = curl("PATCH", "/hello/123/")
    result.not_nil!.body.should eq("Access Denied")
    result.not_nil!.status_code.should eq(403)
  end

  it "should force redirect if force ssl is set" do
    result = curl("DELETE", "/hello/123")
    result.not_nil!.status_code.should eq(302)
    result.not_nil!.headers["location"].not_nil!.should eq("https://localhost/hello/123")
  end

  it "should work with around filters" do
    result = curl("GET", "/hello/around")
    result.not_nil!.body.should eq("var is 133")
    result.not_nil!.status_code.should eq(200)
  end

  it "should reject non-websocket requests to websocket endpoints" do
    result = curl("GET", "/hello/websocket")
    result.not_nil!.body.should eq("This service requires use of the WebSocket protocol")
    result.not_nil!.status_code.should eq(426)
  end

  it "should accept websockets" do
    result = nil
    ws = HTTP::WebSocket.new "localhost", "/hello/websocket", 3000
    ws.on_message do |message|
      result = message
      ws.close
    end
    ws.send "hello"
    ws.run
    result.not_nil!.should eq("hello + 123")
  end

  it "should list routes" do
    BobJane.routes.should eq([
      {:redirect, :get, "/bob_jane/redirect"},
      {:param_id, :get, "/bob_jane/params/:id"},
      {:deep_show, :get, "/bob_jane/params/:id/test/:test_id"},
      {:create, :post, "/bob_jane/post_test"},
      {:update, :put, "/bob_jane/put_test"},
      {:index, :get, "/bob_jane/"},
    ])
  end

  mock_server.close
end
