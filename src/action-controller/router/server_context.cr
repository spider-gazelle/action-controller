require "http/server"

class HTTP::Server::Context
  # helper method for obtaining params extracted from the route path
  property route_params : Hash(String, String) do
    {} of String => String
  end
end
