# :nodoc:
class ActionController::OpenAPI::Operation
  include JSON::Serializable
  include YAML::Serializable

  property summary : String? = nil
  property description : String? = nil

  property tags : Array(String) = [] of String

  # Class#function_name
  @[JSON::Field(key: "operationId")]
  @[YAML::Field(key: "operationId")]
  property operation_id : String? = nil

  @[JSON::Field(key: "requestBody")]
  @[YAML::Field(key: "requestBody")]
  property request_body : Response? = nil
  property parameters : Array(Parameter)? = nil
  property responses : Hash(Int32, Response) = {} of Int32 => Response

  def initialize
  end
end
