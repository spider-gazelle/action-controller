require "json"
require "yaml"

# a series of common errors and rendering helpers for use in your applications
class ActionController::Error < Exception
  # provided for use in your applications
  class Unauthorized < ActionController::Error
  end

  # provided for use in your applications
  class Forbidden < ActionController::Error
  end

  # provided for use in your applications
  class NotFound < ActionController::Error
  end

  # provided for use in your applications
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

# raised if Session::MAX_COOKIE_SIZE is exceeded by a cookie
class ActionController::CookieSizeExceeded < ActionController::Error
end

# the signature of the cookie session is invalid, the cookie may have been tampered with
class ActionController::InvalidSignature < ActionController::Error
end

# raised if a required route parameter is missing
class ActionController::InvalidRoute < ActionController::Error
end
