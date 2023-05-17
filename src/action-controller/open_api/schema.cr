# :nodoc:
class ActionController::OpenAPI::Schema
  include JSON::Serializable
  include YAML::Serializable

  property schema : JSON::Any

  def initialize(@schema : JSON::Any)
  end

  def initialize(schema : String)
    @schema = JSON.parse(schema)
  end
end
