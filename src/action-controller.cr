require "habitat"
require "kilt"
require "log"

module ActionController
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
  # ameba:disable Style/ConstantNames
  Log = ::Log.for("action-controller")
end

require "./action-controller/router"
require "./action-controller/errors"
require "./action-controller/base"
require "./action-controller/file_handler"
require "./action-controller/log_handler"
require "./action-controller/error_handler"
