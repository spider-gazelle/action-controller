require "./spec_helper"

describe "force_tls" do
  client = AC::SpecHelper.client

  it "applies to every route when no only: or except: is given" do
    result = client.get("/force_tls_everywhere/", headers: HTTP::Headers{"Host" => "example.com"})
    result.status_code.should eq 302
    result.headers["Location"].should eq "https://example.com/force_tls_everywhere/"

    secure = client.get("/force_tls_everywhere/", headers: HTTP::Headers{"X-Forwarded-Proto" => "https"})
    secure.status_code.should eq 200
    secure.body.should eq "secure"
  end
end

describe ActionController::Support do
  it "detects the protocol from proxy headers" do
    request = HTTP::Request.new("GET", "/", HTTP::Headers{"X-Forwarded-Proto" => "https"})
    ActionController::Support.request_protocol(request).should eq :https

    request = HTTP::Request.new("GET", "/", HTTP::Headers{"Forwarded" => "for=192.0.2.60;proto=https;by=203.0.113.43"})
    ActionController::Support.request_protocol(request).should eq :https

    request = HTTP::Request.new("GET", "/", HTTP::Headers{"Forwarded" => "for=192.0.2.60;proto=http;host=https.example.com"})
    ActionController::Support.request_protocol(request).should eq :http
  end

  it "detects TLS connections to ports the server bound with TLS" do
    ActionController::Support.tls_ports << 8443
    request = HTTP::Request.new("GET", "/")
    request.local_address = Socket::IPAddress.new("127.0.0.1", 8443)
    ActionController::Support.request_protocol(request).should eq :https

    request.local_address = Socket::IPAddress.new("127.0.0.1", 8080)
    ActionController::Support.request_protocol(request).should eq :http

    # the proxy's view of the client's protocol takes precedence
    request = HTTP::Request.new("GET", "/", HTTP::Headers{"X-Forwarded-Proto" => "http"})
    request.local_address = Socket::IPAddress.new("127.0.0.1", 8443)
    ActionController::Support.request_protocol(request).should eq :http
  ensure
    ActionController::Support.tls_ports.delete(8443)
  end
end
