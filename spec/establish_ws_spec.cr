require "./spec_helper"

# runs the block, failing the spec rather than hanging if it doesn't finish
def within(timeout : Time::Span, &block : -> Nil)
  done = Channel(Exception?).new(1)
  spawn do
    block.call
    done.send nil
  rescue error
    done.send error
  end
  select
  when error = done.receive
    raise error if error
  when timeout(timeout)
    fail "timed out after #{timeout}"
  end
end

describe "establish_ws" do
  client = AC::SpecHelper.client

  it "raises when a filter rejects the handshake" do
    within(5.seconds) do
      expect_raises(Socket::Error, /Status code was 401/) do
        client.establish_ws("/protected_socket/")
      end
    end
  end

  it "connects when the filter allows it" do
    within(5.seconds) do
      websocket = client.establish_ws("/protected_socket/", headers: HTTP::Headers{"Authorization" => "Bearer token"})
      result = nil
      websocket.on_message do |message|
        result = message
        websocket.close
      end
      websocket.send "ping"
      websocket.run
      result.should eq "ping"
    end
  end
end
