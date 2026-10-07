# :nodoc:
class ActionController::OpenAPI::Parameter
  include JSON::Serializable
  include YAML::Serializable

  # name and in not allowed for headers
  property name : String? = nil
  property in : String? = nil
  property description : String? = nil
  property example : JSON::Any? = nil
  property required : Bool? = nil

  # how the value is serialised, i.e. arrays are a comma separated value
  property style : String? = nil
  property explode : Bool? = nil

  property schema : JSON::Any? = nil

  def initialize
  end
end
