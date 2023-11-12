require "json-schema"
require "habitat"
require "./action-controller/logger"

module ActionController
  {% begin %}
    VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
  {% end %}
end

alias AC = ActionController

require "./action-controller/router"
require "./action-controller/errors"
require "./action-controller/base"
require "./action-controller/log_handler"
require "./action-controller/error_handler"
