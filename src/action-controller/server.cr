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

  @server : HTTP::Server?
  @route_handler = RouteHandler.new

  def initialize(@port : Int32, @host = "127.0.0.1")
    {% for klass in ActionController::Base::CONCRETE_CONTROLLERS %}
      {{klass}}.__init_routes__(self)
    {% end %}
  end

  getter :host
  getter :port

  def run
    server = @server = HTTP::Server.new(BEFORE_HANDLERS + [route_handler] + AFTER_HANDLERS)
    server.bind_tcp(@host, @port)
    server.listen
  end

  def close
    if server = @server
      server.close
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
