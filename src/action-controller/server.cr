class ActionController::Server
  include Router

  @server : HTTP::Server?
  @route_handler = RouteHandler.new

  def initialize(@port : Int32, @before_handlers = [] of HTTP::Handler, @after_handlers = [] of HTTP::Handler)
  end

  getter :before_handlers
  getter :after_handlers

  def run
    {% for klass in ActionController::Base::CONCRETE_CONTROLLERS %}
      {{klass}}.draw_routes(self)
    {% end %}
    @server = HTTP::Server.new(@port, @before_handlers + [route_handler] + @after_handlers).listen
  end

  def close
    if server = @server
      server.close
    end
  end

  def self.print_routes
    routes = [] of {Symbol, Symbol, String}
    {% for klass in ActionController::Base::CONCRETE_CONTROLLERS %}
      routes.concat {{klass}}.routes
    {% end %}

    puts "Verb\tURI Pattern\tController#Action"
    routes.each do |route|
      puts "#{route[2]}\t#{route[3]}\t#{route[0]}##{route[1]}"
    end
  end
end
