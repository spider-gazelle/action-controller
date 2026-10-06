require "random/secure"

module ActionController::MCPServer
  # the state of an MCP client connection
  class Session
    getter id : String = Random::Secure.urlsafe_base64(24)
    getter protocol_version : String
    getter last_seen : Time = Time.utc

    # server to client messages awaiting delivery via the GET event stream
    getter notifications : Channel(String) = Channel(String).new(32)

    # the path params bound from an endpoint URL, a session can only be used at that URL
    getter bound : Hash(String, String)

    @open_toolboxes = [] of String
    @lock = Mutex.new

    def initialize(@protocol_version, @bound = {} of String => String)
    end

    def touch : Nil
      @last_seen = Time.utc
    end

    def expired?(timeout : Time::Span) : Bool
      Time.utc - @last_seen > timeout
    end

    def open_toolboxes : Array(String)
      @lock.synchronize { @open_toolboxes.dup }
    end

    # returns `false` if the toolbox was already open
    def open(toolbox : String) : Bool
      @lock.synchronize do
        return false if @open_toolboxes.includes?(toolbox)
        @open_toolboxes << toolbox
        true
      end
    end

    # returns `false` if the toolbox was not open
    def close(toolbox : String) : Bool
      @lock.synchronize { !@open_toolboxes.delete(toolbox).nil? }
    end

    def open?(toolbox : String) : Bool
      @lock.synchronize { @open_toolboxes.includes?(toolbox) }
    end

    # queues a message for the event stream, dropped if the queue is full
    def notify(message : String) : Nil
      select
      when notifications.send(message)
      else
        Log.debug { "notification queue full, dropping message for session #{id}" }
      end
    rescue Channel::ClosedError
    end

    def terminate : Nil
      notifications.close
    end
  end

  # in-memory session storage, sessions are not shared between processes
  class SessionStore
    @sessions = {} of String => Session
    @lock = Mutex.new

    def create(protocol_version : String, bound : Hash(String, String) = {} of String => String) : Session
      session = Session.new(protocol_version, bound)
      @lock.synchronize do
        expire_sessions
        @sessions[session.id] = session
      end
      session
    end

    # returns the active session, refreshing its expiry
    def []?(id : String) : Session?
      @lock.synchronize do
        if session = @sessions[id]?
          if session.expired?(MCPServer.session_timeout)
            @sessions.delete(id)
            session.terminate
            return nil
          end
          session.touch
          session
        end
      end
    end

    def delete(id : String) : Session?
      @lock.synchronize { @sessions.delete(id) }.try &.tap(&.terminate)
    end

    def size : Int32
      @lock.synchronize { @sessions.size }
    end

    private def expire_sessions : Nil
      timeout = MCPServer.session_timeout
      @sessions.reject! do |_id, session|
        session.expired?(timeout).tap { |expired| session.terminate if expired }
      end
    end
  end
end
