# this is used to hold class and method documentation for generating OpenAPI documentation
struct ActionController::OpenAPI::KlassDoc
  include JSON::Serializable
  include YAML::Serializable

  def initialize(@name, @docs : String?)
  end

  getter name : String
  getter docs : String?

  getter methods : Hash(String, String) = {} of String => String
  getter ancestors : Array(String) = [] of String

  def implements?(filter)
    filter_klass = filter[:controller]
    filter_klass == name || ancestors.includes?(filter_klass)
  end
end
