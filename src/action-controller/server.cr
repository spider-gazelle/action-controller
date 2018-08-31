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
    @processes = [] of Concurrent::Future(Nil)
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
    server.bind_tcp(@host, @port, @reuse_port) if server.addresses.empty?
    yield
    server.listen
  end

  def run
    server = @socket.not_nil!
    server.bind_tcp(@host, @port, @reuse_port) if server.addresses.empty?
    server.listen
  end

  def close
    @processes.each(&.get)
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

  def cluster(count)
    count = count.to_i64
    count = System.cpu_count if count <= 0
    return if count <= 1

    # How many and what to start
    count -= 1
    process_path = Process.executable_path

    # Clean up the arguments
    args = ARGV.dup
    args.reject! { |e| e.starts_with?("--cluster") }
    remove = [] of Int32
    args.each_with_index { |value, index| remove << index if value == "-c" }
    remove.each { |index| args.delete_at(index, 2) }

    # Start the processes
    (0_i64...count).each do
      @processes << future do
        process = nil
        Process.run(process_path.not_nil!, args,
          input: Process::Redirect::Close,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit
        ) do |ref|
          process = ref
          puts " > cluster started #{process.pid}"
        end
        status = $?
        process = process.not_nil!
        if status.success?
          puts " < cluster stopped #{process.pid}"
        else
          puts " ! cluster process #{process.pid} failed with #{status.exit_status}"
        end
        nil
      end
    end
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
