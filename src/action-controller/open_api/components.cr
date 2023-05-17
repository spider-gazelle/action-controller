# :nodoc:
class ActionController::OpenAPI::Components
  include JSON::Serializable
  include YAML::Serializable

  property schemas : Hash(String, JSON::Any) = {} of String => JSON::Any

  def initialize
  end
end
