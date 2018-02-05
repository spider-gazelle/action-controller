class ActionController::Server
  include Router

  @server : HTTP::Server?
  @route_handler = RouteHandler.new

  def initialize(@port : Int32, @host = "127.0.0.1", @before_handlers = [] of HTTP::Handler, @after_handlers = [] of HTTP::Handler)
    {% for klass in ActionController::Base::CONCRETE_CONTROLLERS %}
      {{klass}}.__init_routes__(self)
    {% end %}
  end

  getter :host
  getter :port
  getter :before_handlers
  getter :after_handlers

  def run
    server = @server = HTTP::Server.new(@host, @port, @before_handlers + [route_handler] + @after_handlers)
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
