class ActionController::Server
  include Router

  BEFORE_HANDLERS = [] of HTTP::Handler
  AFTER_HANDLERS  = [] of HTTP::Handler

  def self.before(*handlers)
    BEFORE_HANDLERS.concat(handlers)
  end

  def self.after(*handlers)
    AFTER_HANDLERS.concat(handlers)
  end

  @socket : HTTP::Server?
  @route_handler = RouteHandler.new

  def initialize(@port = 3000, @host = "127.0.0.1", @reuse_port = true)
    {% for klass in ActionController::Base::CONCRETE_CONTROLLERS %}
      {{klass}}.__init_routes__(self)
    {% end %}

    @socket = HTTP::Server.new(BEFORE_HANDLERS + [route_handler] + AFTER_HANDLERS)
  end

  getter :host
  getter :port

  # Provides access the HTTP server for the purpose of binding
  # For example `server.socket.bind_unix "/tmp/my-socket.sock"`
  def socket
    @socket.not_nil!
  end

  def run
    server = @socket.not_nil!
    if server.addresses.empty?
      server.bind_tcp(@host, @port, @reuse_port)
      server.listen
    else
      server.listen
    end
  end

  def close
    socket.close
  end

  def print_addresses
    socket.addresses.map { |socket|
      family = socket.family

      case socket.family
      when Socket::Family::INET6, Socket::Family::INET
        ip = Socket::IPAddress.from(socket.to_unsafe, socket.size)
        "http://#{ip.address}:#{ip.port}"
      when Socket::Family::UNIX
        unix = Socket::UNIXAddress.from(socket.to_unsafe, socket.size)
        "unix://#{unix.path}"
      else
        raise "Unsupported family type: #{family} (#{family.value})"
      end
    }.join(" , ")
  end

  def self.print_routes
    # Class, name, verb, route
    routes = [] of {String, Symbol, Symbol, String}
    {% for klass in ActionController::Base::CONCRETE_CONTROLLERS %}
      routes.concat {{klass}}.__route_list__
    {% end %}

    puts "Verb\tURI Pattern\tController#Action"
    routes.each do |route|
      puts "#{route[2]}\t#{route[3]}\t#{route[0]}##{route[1]}"
    end
  end
end
