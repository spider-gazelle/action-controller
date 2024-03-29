require "./open_api"

class ActionController::Server
  include Router

  # :nodoc:
  BEFORE_HANDLERS = [] of HTTP::Handler

  # :nodoc:
  AFTER_HANDLERS = [] of HTTP::Handler

  # handlers to run before your application code, see: [handlers](https://crystal-lang.org/api/latest/HTTP/Handler.html)
  #
  # configure these in your [config.cr file](https://github.com/spider-gazelle/spider-gazelle/blob/master/src/config.cr)
  def self.before(*handlers)
    BEFORE_HANDLERS.concat(handlers)
  end

  # handlers to run after your application code, see: [handlers](https://crystal-lang.org/api/latest/HTTP/Handler.html)
  #
  # these will only be run if the route is not found in your application
  def self.after(*handlers)
    AFTER_HANDLERS.concat(handlers)
  end

  @route_handler = RouteHandler.new

  # reuse port is only useful for broadcast or multicast applications on windows
  # when used with TCP it is considered a security risk as the port can be stolen
  REUSE_DEFAULT = {% if flag?(:win32) %} false {% else %} true {% end %}

  # create an instance of the application
  def initialize(@port = 3000, @host = "127.0.0.1", @reuse_port : Bool = REUSE_DEFAULT)
    @processes = 0
    @process_closed = Channel(Nil).new
    init_routes
    @socket = HTTP::Server.new(BEFORE_HANDLERS + [route_handler] + AFTER_HANDLERS)
  end

  # create an instance of the application with tls
  def initialize(@ssl_context : OpenSSL::SSL::Context::Server?, @port = 3000, @host = "127.0.0.1", @reuse_port : Bool = REUSE_DEFAULT)
    @processes = 0
    @process_closed = Channel(Nil).new
    init_routes
    @socket = HTTP::Server.new(BEFORE_HANDLERS + [route_handler] + AFTER_HANDLERS)
  end

  private def init_routes
    {% for klass in ActionController::Base::CONCRETE_CONTROLLERS %}
      {{klass}}.__init_routes__(self)
    {% end %}
  end

  # :nodoc:
  def reload
    return unless @socket.closed?
    @socket = HTTP::Server.new(BEFORE_HANDLERS + [route_handler] + AFTER_HANDLERS)
  end

  # the host address the server is configured to run on
  getter host

  # the port the server is accepting connections from
  getter port

  # Provides access the HTTP server for the purpose of binding
  # For example `server.socket.bind_unix "/tmp/my-socket.sock"`
  getter socket : HTTP::Server

  # Starts the server, providing a callback once the ports are bound
  def run(&) : Nil
    if @socket.addresses.empty?
      if ssl_context = @ssl_context
        @socket.bind_tls(@host, @port, ssl_context, @reuse_port)
      else
        @socket.bind_tcp(@host, @port, @reuse_port)
      end
    end
    yield
    @socket.listen
  end

  # Starts the server
  def run : Nil
    if @socket.addresses.empty?
      if ssl_context = @ssl_context
        @socket.bind_tls(@host, @port, ssl_context, @reuse_port)
      else
        @socket.bind_tcp(@host, @port, @reuse_port)
      end
    end
    "Listening on #{print_addresses}"
    @socket.listen
  end

  # Terminates the application gracefully once any cluster processes have exited
  def close : Nil
    @processes.times { @process_closed.receive }
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
    process_path = Process.executable_path.as(String)

    # Clean up the arguments
    args.reject! &.starts_with?(long_arg)
    remove = [] of Int32
    args.each_with_index { |value, index| remove << index if value == short_arg }
    remove.each { |index| args.delete_at(index, 2) }

    # Start the processes
    (0_i64...count).each do
      @processes += 1
      spawn do
        process = uninitialized Process
        Process.run(process_path, args,
          input: Process::Redirect::Close,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit
        ) do |ref|
          process = ref
          puts " > worker #{process.pid} started"
        end
        status = $?
        if status.success?
          puts " < worker #{process.pid} stopped"
        else
          puts " ! worker process #{process.pid} failed with #{status.exit_status}"
        end
        @process_closed.send nil
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

    @processes = processes.size
    processes.each do |process|
      spawn do
        status = process.wait
        if status.success?
          puts " < worker #{process.pid} stopped"
        else
          puts " ! worker process #{process.pid} failed with #{status.exit_status}"
        end
        @process_closed.send nil
      end
    end
  end

  # returns a list of the routes defined in the application
  #
  # responds with `[{"ControllerClass", :name, :verb, "/route"}]`
  def self.routes : Array(Tuple(String, Symbol, Symbol, String))
    # Class, name, verb, route
    routes = [] of {String, Symbol, Symbol, String}
    {% for klass in ActionController::Base::CONCRETE_CONTROLLERS %}
      routes.concat {{klass}}.__route_list__
    {% end %}
    routes
  end

  # Used to output route details to the console from a command line switch
  def self.print_routes
    headers = {"Controller", :Action, :Verb, "URI Pattern"}
    sizes = component_sizes(*headers)
    self.routes.each do |route|
      route_size = component_sizes(*route)
      sizes = max_size(sizes, route_size)
    end

    print_route(sizes, headers)
    self.routes.each { |route| print_route(sizes, route) }
  end

  protected def self.component_sizes(*args) : Array(Int32)
    sizes = Array(Int32).new(args.size)
    args.each { |part| sizes << part.to_s.size }
    sizes
  end

  protected def self.max_size(current : Array(Int32), other : Array(Int32)) : Array(Int32)
    max = Array(Int32).new(current.size)
    current.each_with_index do |item, index|
      comp = other[index]
      max << (item >= comp ? item : comp)
    end
    max
  end

  protected def self.print_route(sizes, details)
    sizes = {sizes[0] + sizes[1] + 1, sizes[2]}
    details = {"#{details[0]}##{details[1]}", details[2], details[3]}
    printf("%-#{sizes[0]}s %-#{sizes[1]}s %s\n", details)
  end
end
