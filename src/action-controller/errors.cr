require "json"
require "yaml"

class ActionController::Error < Exception
  class Unauthorized < ActionController::Error
  end

  class Forbidden < ActionController::Error
  end

  class NotFound < ActionController::Error
  end

  class Conflict < ActionController::Error
  end

  # provides a response object for rendering errors
  struct CommonResponse
    include JSON::Serializable
    include YAML::Serializable

    getter error : String?
    getter backtrace : Array(String)?

    def initialize(error, backtrace = true)
      @error = error.message
      @backtrace = backtrace ? error.backtrace : nil
    end
  end

  # Provides details on available data formats
  struct ContentResponse
    include JSON::Serializable
    include YAML::Serializable

    getter error : String
    getter accepts : Array(String)? = nil

    def initialize(@error, @accepts = nil)
    end
  end

  # Provides details on which parameter is missing or invalid
  struct ParameterResponse
    include JSON::Serializable
    include YAML::Serializable

    getter error : String
    getter parameter : String? = nil
    getter restriction : String? = nil

    def initialize(@error, @parameter = nil, @restriction = nil)
    end
  end
end

class ActionController::CookieSizeExceeded < ActionController::Error
end

class ActionController::InvalidSignature < ActionController::Error
end

class ActionController::InvalidRoute < ActionController::Error
end
