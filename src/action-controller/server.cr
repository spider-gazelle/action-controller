class ActionController::Server
  include Router

  @server : HTTP::Server?
  @route_handler = RouteHandler.new

  def initialize(@port : Int32)
  end

  def run
    {% for klass in ActionController::Base::CONCRETE_CONTROLLERS %}
      {{klass}}.draw_routes(self)
    {% end %}
    @server = HTTP::Server.new(@port, [route_handler]).listen
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
      puts "#{route[1]}\t#{route[2]}\t#{route[0]}"
    end
  end
end
