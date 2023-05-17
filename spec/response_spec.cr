require "./spec_helper"

describe "end to end requests and responses" do
  client = AC::SpecHelper.client

  it "#index" do
    result = client.get("/bob_jane/")
    result.body.should eq("index")
  end

  it "creates and works with session data" do
    result = client.get("/bob_jane/")
    result.body.should eq("index")
    cookie = result.headers["Set-Cookie"]
    cookie.starts_with?("_test_session_=").should eq(true)

    cookie = cookie.split("%3B")[0]
    result = client.get("/bob_jane/redirect", headers: HTTP::Headers{"Cookie" => cookie})
    result.headers["Location"].should eq("/other_route")
  end

  it "can modify session cookie data in an before_action" do
    result = client.get("/bob_jane/modified_session")
    result.body.should eq("ok")
    cookie = result.headers["Set-Cookie"]
    cookie.starts_with?("_test_session_=").should eq(true)
    cookie.should contain "domain=bobjane.com"
  end

  it "encode session cookie when redirect_to" do
    result = client.get("/bob_jane/modified_session_with_redirect")
    result.headers["Set-Cookie"].should_not be_nil
  end

  it "encode body as application/x-www-form-urlencoded" do
    headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
    body = "name=Jane"
    result = client.get("/bob_jane/urlencoded", headers: headers, body: body)
    result.body.should eq("Jane")
  end

  it "#redirect" do
    cookie = "_test_session_=CKQMLS12oJZBIh3Hlbpg19XGFAphCiRW7NMHq31epbpGTfI9N0T7WeIR1C%2FFDJ%2FW--IEb0qAXKV9DtrLdnyqzdGbBM2ww%3D"
    result = client.get("/bob_jane/redirect", headers: HTTP::Headers{"Cookie" => cookie})
    result.headers["Location"].should eq("/other_route")
  end

  it "#params" do
    result = client.get("/bob_jane/params/1")
    result.body.should eq("params:1")
    result = client.get("/bob_jane/params/2")
    result.body.should eq("params:2")
  end

  it "#test_param" do
    result = client.get("/bob_jane/params/1/test/3")
    result.status_code.should eq(200)
    result.body.should eq("{\"id\":\"1\",\"test_id\":\"3\"}")
    result = client.get("/bob_jane/params/2/test/4")
    result.body.should eq("{\"id\":\"2\",\"test_id\":\"4\"}")
  end

  it "#post_test" do
    result = client.post("/bob_jane/post_test/")
    result.body.should eq("ok")
    result.status_code.should eq(202)
  end

  it "#put_test" do
    result = client.put("/bob_jane/put_test/")
    result.body.should eq("ok")
  end

  it "#unknown_path" do
    result = client.get("/bob_jane/unknown_path")
    result.status_code.should eq(404)
  end

  it "should work with inheritance" do
    result = client.get("/hello/2")
    result.status_code.should eq(200)
    result.body.should eq("42 / 2 = 21")
  end

  it "should prioritise route params" do
    result = client.get("/hello/2?id=7")
    result.status_code.should eq(200)
    result.body.should eq("42 / 2 = 21")
  end

  it "should rescue errors as required" do
    result = client.get("/hello/0")
    result.body.should eq("Division by 0")
    result.status_code.should eq(400)
  end

  it "should perform before actions and execute the action" do
    result = client.get("/hello/")
    result.body.should eq("set_var 123")
    result.status_code.should eq(200)
  end

  it "should select the appropriate response type" do
    result = client.get("/hello/", headers: HTTP::Headers{"Accept" => "text/yaml, application/json, text/plain"})
    result.body.should eq("{\"set_var\":123}")
    result.status_code.should eq(200)

    result = client.get("/hello/", headers: HTTP::Headers{"Accept" => "text/yaml"})
    result.body.should eq("")
    result.status_code.should eq(406)

    result = client.get("/hello/", headers: HTTP::Headers{"Accept" => "text/xml"})
    result.body.should eq("<?xml version=\"1.0\"?>\n<set_var>123</set_var>\n")
    result.status_code.should eq(200)

    result = client.head("/hello/", headers: HTTP::Headers{"Accept" => "text/xml"})
    result.body.should eq("")
    result.status_code.should eq(200)
  end

  it "should stop callbacks if render is called in a before filter" do
    result = client.patch("/hello/123/")
    result.body.should eq("Access Denied")
    result.status_code.should eq(403)
  end

  it "should force redirect if force ssl is set" do
    result = client.delete("/hello/123", headers: HTTP::Headers{"Host" => "localhost"})
    result.status_code.should eq(302)
    result.headers["location"].should eq("https://localhost/hello/123")
  end

  it "should work with around filters" do
    result = client.get("/hello/around")
    result.body.should eq("var is 133")
    result.status_code.should eq(200)
  end

  it "should work with HEAD requests" do
    result = client.head("/hello/around")
    result.body.empty?.should eq(true)
    result.status_code.should eq(200)
  end

  it "should reject non-websocket requests to websocket endpoints" do
    result = client.get("/hello/websocket")
    result.body.should eq("This service requires use of the WebSocket protocol")
    result.status_code.should eq(426)
  end

  it "should accept websockets" do
    websocket = client.establish_ws("/hello/websocket")

    result = nil
    websocket.on_message do |message|
      result = message
      websocket.close
    end
    websocket.send "hello"
    websocket.run
    result.should eq("hello + 123")
  end

  it "should list routes" do
    BobJane.__route_list__.should eq([
      {"BobJane", :index, :get, "/bob_jane/"},
      {"BobJane", :redirect, :get, "/bob_jane/redirect"},
      {"BobJane", :param_id, :get, "/bob_jane/params/:id"},
      {"BobJane", :deep_show, :get, "/bob_jane/params/:id/test/:test_id"},
      {"BobJane", :create, :post, "/bob_jane/post_test"},
      {"BobJane", :update, :put, "/bob_jane/put_test"},
      {"BobJane", :modified_session, :get, "/bob_jane/modified_session"},
      {"BobJane", :modified_session_with_redirect, :get, "/bob_jane/modified_session_with_redirect"},
      {"BobJane", :urlencoded, :get, "/bob_jane/urlencoded"},
    ])
  end

  it "should return the available params in priority order" do
    result = client.post("/template_one/params/hello?testing=123&other=and&yes=no", headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}, body: "acc=4&topic=%2A")
    result.body.should eq("testing other yes yes acc topic")
    result.headers["Values"].should eq("123 and hello no 4 *")
  end
end
