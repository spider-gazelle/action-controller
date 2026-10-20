module ActionController::MCPServer
  # :nodoc:
  # a `subscriptions/listen` stream. Resource changes are coalesced, see
  # `MCPServer.update_debounce`, and sent as `notifications/resources/updated` until the
  # client disconnects, `MCPServer.listen_timeout` expires or the subscription is closed
  class Subscription
    getter uris : Array(String) = [] of String

    @stops = [] of Proc(Nil)
    @pending = Set(String).new
    @lock = Mutex.new
    @write_lock = Mutex.new
    @changes = Channel(Nil).new(1)
    @closed = Channel(Nil).new
    @stopped = false

    def initialize(@response : HTTP::Server::Response, @id : JSON::Any)
    end

    def meta : Hash(String, JSON::Any)
      {Transport::META_SUBSCRIPTION => @id}
    end

    def size : Int32
      uris.size
    end

    # a resource is being watched, `stop` stops watching it
    def add(uri : String, stop : Proc(Nil)) : Nil
      @lock.synchronize do
        uris << uri
        @stops << stop
      end
    end

    # called by watchers when a resource changes, from any fiber
    def changed(uri : String) : Nil
      @lock.synchronize { @pending << uri }
      select
      when @changes.send(nil)
      else
        # a flush is already pending
      end
    end

    # sends updates until the client disconnects, raising `HTTP::Server::ClientError`, or the
    # subscription ends
    def run : Nil
      deadline = MCPServer.listen_timeout.try { |timeout| Time.instant + timeout }
      last_flush = Time.instant - MCPServer.update_debounce

      loop do
        wait = MCPServer.keep_alive
        if deadline
          remaining = deadline - Time.instant
          return complete if remaining <= Time::Span.zero
          wait = remaining if remaining < wait
        end

        select
        when @changes.receive
          # coalesce bursts of changes
          pause = last_flush + MCPServer.update_debounce - Time.instant
          sleep pause if pause > Time::Span.zero
          flush
          last_flush = Time.instant
        when @closed.receive?
          return complete
        when timeout(wait)
          write(":\r\n")
        end
      end
    end

    # completes the subscription, telling the client it ended gracefully
    def complete : Nil
      write("event: message\ndata: #{{jsonrpc: "2.0", id: @id, result: {resultType: "complete", _meta: meta}}.to_json}\n\n")
    rescue IO::Error | HTTP::Server::ClientError
      # the client disconnected
    end

    # ends the subscription, see `Transport#close_subscriptions`
    def close : Nil
      @closed.close
    end

    # stops watching every resource
    def stop : Nil
      stops = @lock.synchronize do
        return if @stopped
        @stopped = true
        @stops.dup
      end
      stops.each do |stop|
        stop.call
      rescue error
        Log.error(exception: error) { "MCP failed to stop watching a resource" }
      end
    end

    private def flush : Nil
      updated = @lock.synchronize do
        changes = @pending.to_a
        @pending.clear
        changes
      end
      updated.each do |uri|
        write("event: message\ndata: #{{jsonrpc: "2.0", method: "notifications/resources/updated", params: {uri: uri, _meta: meta}}.to_json}\n\n")
      end
    end

    private def write(message : String) : Nil
      @write_lock.synchronize do
        @response << message
        @response.flush
      end
    end
  end
end
