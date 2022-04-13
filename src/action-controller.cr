require "habitat"
require "future"
require "./action-controller/logger"

module ActionController
  macro set_version
    VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
  end

  set_version
end

# maintain basic backwards compatibility
{% if compare_versions(Crystal::VERSION, "0.36.0") < 0 %}
  require "uri"
  require "http"

  class URI
    alias Params = HTTP::Params
  end
{% end %}

require "./action-controller/router"
require "./action-controller/errors"
require "./action-controller/base"
require "./action-controller/file_handler"
require "./action-controller/log_handler"
require "./action-controller/error_handler"
