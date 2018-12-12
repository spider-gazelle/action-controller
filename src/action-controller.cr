require "kilt"
require "logger"
require "habitat"

module ActionController
  VERSION = "1.0.1"

  class Error < ::Exception
  end
end

require "./action-controller/router"
require "./action-controller/errors"
require "./action-controller/base"
require "./action-controller/file_handler"
