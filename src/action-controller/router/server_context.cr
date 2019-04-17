require "http/server"

# Adds a helper method for storing params extracted from radix tree routes
class HTTP::Server::Context
  @route_params : Hash(String, String)?
  setter route_params

  def route_params : Hash(String, String)
    @route_params || {} of String => String
  end
end
