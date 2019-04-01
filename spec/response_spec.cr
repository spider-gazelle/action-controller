require "./spec_helper"

describe "end to end requests and responses" do
  with_server do |app|
    it "#index" do
      result = curl("GET", "/bob_jane/")
      result.body.should eq("index")
    end

    it "supports printing addresses" do
      app.print_addresses.should eq("http://127.0.0.1:6000 , unix:///tmp/spider-socket.sock")
    end

    it "creates and works with session data" do
      result = curl("GET", "/bob_jane/")
      result.body.should eq("index")
      cookie = result.headers["Set-Cookie"]
      cookie.starts_with?("_test_session_=").should eq(true)

      cookie = cookie.split("%3B")[0]
      result = curl("GET", "/bob_jane/redirect", {"Cookie" => cookie})
      result.headers["Location"].should eq("/other_route")
    end

    it "can modify session cookie data in an after_action" do
      result = curl("GET", "/bob_jane/modified_session")
      result.body.should eq("ok")
      cookie = result.headers["Set-Cookie"]
      cookie.starts_with?("_test_session_=").should eq(true)
      cookie.should contain "domain=bobjane.com"
    end

    it "#redirect" do
      cookie = "_test_session_=CKQMLS12oJZBIh3Hlbpg19XGFAphCiRW7NMHq31epbpGTfI9N0T7WeIR1C%2FFDJ%2FW--IEb0qAXKV9DtrLdnyqzdGbBM2ww%3D"
      result = curl("GET", "/bob_jane/redirect", {"Cookie" => cookie})
      result.headers["Location"].should eq("/other_route")
    end

    it "#params" do
      result = curl("GET", "/bob_jane/params/1")
      result.body.should eq("params:1")
      result = curl("GET", "/bob_jane/params/2")
      result.body.should eq("params:2")
    end

    it "#test_param" do
      result = curl("GET", "/bob_jane/params/1/test/3")
      result.status_code.should eq(200)
      result.body.should eq("{\"id\":\"1\",\"test_id\":\"3\"}")
      result = curl("GET", "/bob_jane/params/2/test/4")
      result.body.should eq("{\"id\":\"2\",\"test_id\":\"4\"}")
    end

    it "#post_test" do
      result = curl("POST", "/bob_jane/post_test/")
      result.body.should eq("ok")
      result.status_code.should eq(202)
    end

    it "#put_test" do
      result = curl("PUT", "/bob_jane/put_test/")
      result.body.should eq("ok")
    end

    it "#unknown_path" do
      result = curl("GET", "/bob_jane/unknown_path")
      result.status_code.should eq(404)
    end

    it "should work with inheritance" do
      result = curl("GET", "/hello/2")
      result.status_code.should eq(200)
      result.body.should eq("42 / 2 = 21")
    end

    it "should prioritise route params" do
      result = curl("GET", "/hello/2?id=7")
      result.status_code.should eq(200)
      result.body.should eq("42 / 2 = 21")
    end

    it "should rescue errors as required" do
      result = curl("GET", "/hello/0")
      result.body.should eq("Division by 0")
      result.status_code.should eq(400)
    end

    it "should perform before actions and execute the action" do
      result = curl("GET", "/hello/")
      result.body.should eq("set_var 123")
      result.status_code.should eq(200)
    end

    it "should select the appropriate response type" do
      result = curl("GET", "/hello/", {"Accept" => "text/yaml, application/json, text/plain"})
      result.body.should eq("{\"set_var\":123}")
      result.status_code.should eq(200)

      result = curl("GET", "/hello/", {"Accept" => "text/yaml"})
      result.body.should eq("")
      result.status_code.should eq(406)

      result = curl("GET", "/hello/", {"Accept" => "text/xml"})
      result.body.should eq("<?xml version=\"1.0\"?>\n<set_var>123</set_var>\n")
      result.status_code.should eq(200)

      result = curl("HEAD", "/hello/", {"Accept" => "text/xml"})
      result.body.should eq("")
      result.status_code.should eq(200)
    end

    it "should stop callbacks if render is called in a before filter" do
      result = curl("PATCH", "/hello/123/")
      result.body.should eq("Access Denied")
      result.status_code.should eq(403)
    end

    it "should force redirect if force ssl is set" do
      result = curl("DELETE", "/hello/123")
      result.status_code.should eq(302)
      result.headers["location"].should eq("https://localhost/hello/123")
    end

    it "should work with around filters" do
      result = curl("GET", "/hello/around")
      result.body.should eq("var is 133")
      result.status_code.should eq(200)
    end

    it "should work with HEAD requests" do
      result = curl("HEAD", "/hello/around")
      result.body.empty?.should eq(true)
      result.status_code.should eq(200)
    end

    it "should reject non-websocket requests to websocket endpoints" do
      result = curl("GET", "/hello/websocket")
      result.body.should eq("This service requires use of the WebSocket protocol")
      result.status_code.should eq(426)
    end

    it "should accept websockets" do
      result = nil
      ws = HTTP::WebSocket.new "localhost", "/hello/websocket", 6000
      ws.on_message do |message|
        result = message
        ws.close
      end
      ws.send "hello"
      ws.run
      result.should eq("hello + 123")
    end

    it "should list routes" do
      BobJane.__route_list__.should eq([
        {"BobJane", :redirect, :get, "/bob_jane/redirect"},
        {"BobJane", :param_id, :get, "/bob_jane/params/:id"},
        {"BobJane", :deep_show, :get, "/bob_jane/params/:id/test/:test_id"},
        {"BobJane", :create, :post, "/bob_jane/post_test"},
        {"BobJane", :update, :put, "/bob_jane/put_test"},
        {"BobJane", :modified_session, :get, "/bob_jane/modified_session"},
        {"BobJane", :index, :get, "/bob_jane/"},
      ])
    end

    it "should return the available params in priority order" do
      result = curl("GET", "/template_one/params/hello?testing=123&other=and&yes=no")
      result.body.should eq("testing other yes yes")
      result.headers["Values"].should eq("123 and hello no")
    end
  end
end
