# :nodoc:
class ActionController::OpenAPI::Parameter
  include JSON::Serializable
  include YAML::Serializable

  # name and in not allowed for headers
  property name : String? = nil
  property in : String? = nil
  property description : String? = nil
  property example : String? = nil
  property required : Bool? = nil

  property schema : JSON::Any? = nil

  def initialize
  end
end
