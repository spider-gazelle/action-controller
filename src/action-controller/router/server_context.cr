require "http/server"

class HTTP::Server::Context
  # :nodoc:
  property controller_base : String?
  # helper method for obtaining params extracted from the route path
  property route_params : Hash(String, String) do
    {} of String => String
  end

  # :nodoc:
  # Keep empty path bindings lazy and avoid mutating an upstream handler's hash.
  def reset_route_params : Nil
    @route_params = nil
  end
end
