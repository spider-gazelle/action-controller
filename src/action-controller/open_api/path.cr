class ActionController::OpenAPI::Components
  include JSON::Serializable
  include YAML::Serializable

  property schemas : Hash(String, Schema) = {} of String => Schema
end

class ActionController::OpenAPI::Path
  include JSON::Serializable
  include YAML::Serializable

  property summary : String? = nil
  property description : String? = nil

  property get : Operation? = nil
  property put : Operation? = nil
  property post : Operation? = nil
  property delete : Operation? = nil
  property options : Operation? = nil
  property head : Operation? = nil
  property patch : Operation? = nil
end

class ActionController::OpenAPI::Operation
  include JSON::Serializable
  include YAML::Serializable

  property summary : String? = nil
  property description : String? = nil

  # Class#function_name
  @[JSON::Field(key: "operationId")]
  @[YAML::Field(key: "operationId")]
  property operation_id : String? = nil

  @[JSON::Field(key: "requestBody")]
  @[YAML::Field(key: "requestBody")]
  property request_body : Response? = nil
  property parameters : Array(Parameter)? = nil
  property responses : Hash(String, Response) = {} of String => Response
end

class ActionController::OpenAPI::Reference
  include JSON::Serializable
  include YAML::Serializable

  @[JSON::Field(key: "$ref")]
  @[YAML::Field(key: "$ref")]
  property ref : String

  def initialize(@ref)
  end
end

class ActionController::OpenAPI::Response
  include JSON::Serializable
  include YAML::Serializable

  property description : String? = nil
  property headers : Hash(String, Parameter)? = nil
  property content : Hash(String, Schema)? = nil
  property required : Bool? = nil
end

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

class ActionController::OpenAPI::Parameter
  include JSON::Serializable
  include YAML::Serializable

  # name and in not allowed for headers
  property name : String? = nil
  property in : String? = nil
  property description : String? = nil
  property required : Bool? = nil

  property schema : Schema? = nil
end
