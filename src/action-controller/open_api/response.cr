# :nodoc:
class ActionController::OpenAPI::Response
  include JSON::Serializable
  include YAML::Serializable

  property description : String? = nil
  property headers : Hash(String, Parameter)? = nil
  property content : Hash(String, Schema)? = nil
  property required : Bool? = nil

  def initialize
  end
end
