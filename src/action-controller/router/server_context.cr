require "http/server"

# Adds a helper method for storing params extracted from radix tree routes
class HTTP::Server::Context
  property route_params : Hash(String, String) do
    {} of String => String
  end
end
