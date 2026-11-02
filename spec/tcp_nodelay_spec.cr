require "./spec_helper"

private def nodelay_test_server
  ActionController::Server::HTTPServer.new do |context|
    context.response << %({"ok":true})
    # Commits the response to chunked encoding, so the terminating chunk is a
    # separate small write: the case Nagle holds for the client's delayed ACK.
    context.response.flush
  end
end

describe ActionController::Server::HTTPServer do
  it "disables Nagle on TCP listeners and the connections they accept" do
    listener = TCPServer.new("127.0.0.1", 0)
    nodelay_test_server.bind(listener)
    listener.tcp_nodelay?.should be_true

    client = TCPSocket.new("127.0.0.1", listener.local_address.port)
    accepted = listener.accept
    begin
      accepted.tcp_nodelay?.should be_true
    ensure
      accepted.close
      client.close
      listener.close
    end
  end

  it "disables Nagle on the TCP listener wrapped by a TLS server" do
    listener = TCPServer.new("127.0.0.1", 0)
    nodelay_test_server.bind(OpenSSL::SSL::Server.new(listener, OpenSSL::SSL::Context::Server.new))
    listener.tcp_nodelay?.should be_true
  ensure
    listener.try &.close
  end

  it "doesn't stall flushed responses on a keep-alive connection" do
    server = nodelay_test_server
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield

    client = HTTP::Client.new("127.0.0.1", address.port)
    begin
      client.get("/").body.should eq %({"ok":true})
      elapsed = Time.measure do
        10.times { client.get("/").body.should eq %({"ok":true}) }
      end
      # Nagle with delayed ACKs costs ~40ms per response on Linux.
      elapsed.should be < 200.milliseconds
    ensure
      client.close
      server.close
    end
  end
end
