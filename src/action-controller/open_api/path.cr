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

  def initialize
  end
end
