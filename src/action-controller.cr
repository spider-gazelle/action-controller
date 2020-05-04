require "habitat"
require "future"
require "./action-controller/logger"

module ActionController
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
end

require "./action-controller/router"
require "./action-controller/errors"
require "./action-controller/base"
require "./action-controller/file_handler"
require "./action-controller/log_handler"
require "./action-controller/error_handler"
