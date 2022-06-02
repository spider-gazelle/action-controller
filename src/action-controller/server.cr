class ActionController::Server
  include Router

  BEFORE_HANDLERS = [] of HTTP::Handler
  AFTER_HANDLERS  = [] of HTTP::Handler

  # Adds handlers that should run before routes in this application
  def self.before(*handlers)
    BEFORE_HANDLERS.concat(handlers)
  end

  # Adds handlers that should run if a route is not found
  def self.after(*handlers)
    AFTER_HANDLERS.concat(handlers)
  end

  @route_handler = RouteHandler.new

  def initialize(@port = 3000, @host = "127.0.0.1", @reuse_port = true)
    @processes = [] of Future::Compute(Nil)
    init_routes
    @socket = HTTP::Server.new(BEFORE_HANDLERS + [route_handler] + AFTER_HANDLERS)
  end

  private def init_routes
    {% for klass in ActionController::Base::CONCRETE_CONTROLLERS %}
      {{klass}}.__init_routes__(self)
    {% end %}
  end

  def reload
    return unless @socket.closed?
    @processes.clear
    @socket = HTTP::Server.new(BEFORE_HANDLERS + [route_handler] + AFTER_HANDLERS)
  end

  getter host
  getter port

  # Provides access the HTTP server for the purpose of binding
  # For example `server.socket.bind_unix "/tmp/my-socket.sock"`
  getter socket : HTTP::Server

  # Starts the server, providing a callback once the ports are bound
  def run
    @socket.bind_tcp(@host, @port, @reuse_port) if @socket.addresses.empty?
    yield
    @socket.listen
  end

  # Starts the server
  def run
    @socket.bind_tcp(@host, @port, @reuse_port) if @socket.addresses.empty?
    "Listening on #{print_addresses}"
    @socket.listen
  end

  # Terminates the application gracefully once any cluster processes have exited
  def close
    @processes.each(&.get)
    @socket.close
  end

  # Prints the addresses that the server is listening on
  def print_addresses
    @socket.addresses.join(" , ") { |socket|
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
    }
  end

  # Launches additional worker processes
  # removing the short and long arguments that trigger this method
  def cluster(count, short_arg, long_arg, args = ARGV.dup)
    count = count.to_i64
    count = System.cpu_count if count <= 0
    return if count <= 1

    # How many and what to start
    count -= 1
    process_path = Process.executable_path.not_nil!

    # Clean up the arguments
    args.reject! &.starts_with?(long_arg)
    remove = [] of Int32
    args.each_with_index { |value, index| remove << index if value == short_arg }
    remove.each { |index| args.delete_at(index, 2) }

    # Start the processes
    (0_i64...count).each do
      @processes << future do
        process = nil
        Process.run(process_path, args,
          input: Process::Redirect::Close,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit
        ) do |ref|
          process = ref
          puts " > worker #{process.pid} started"
        end
        status = $?
        process = process.not_nil!
        if status.success?
          puts " < worker #{process.pid} stopped"
        else
          puts " ! worker process #{process.pid} failed with #{status.exit_status}"
        end
        nil
      end
    end
  end

  # Forks additional worker processes
  def cluster(count)
    count = count.to_i64
    count = System.cpu_count if count <= 0
    return if count <= 1

    # How many we actually want to start
    count -= 1

    processes = [] of Process
    (0_i64...count).each do
      # returns a nil process in the fork
      process = Process.fork
      return unless process
      processes << process
    end

    processes.each do |process|
      @processes << future do
        status = process.wait
        if status.success?
          puts " < worker #{process.pid} stopped"
        else
          puts " ! worker process #{process.pid} failed with #{status.exit_status}"
        end
        nil
      end
    end
  end

  def self.routes
    # Class, name, verb, route
    routes = [] of {String, Symbol, Symbol, String}
    {% for klass in ActionController::Base::CONCRETE_CONTROLLERS %}
      routes.concat {{klass}}.__route_list__
    {% end %}
    routes
  end

  # Used to output route details to the console from a command line switch
  def self.print_routes
    puts "Verb\tURI Pattern\tController#Action"
    self.routes.each do |route|
      puts "#{route[2]}\t#{route[3]}\t#{route[0]}##{route[1]}"
    end
  end
end
