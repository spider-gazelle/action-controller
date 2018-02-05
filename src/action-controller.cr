require "logger"
require "router"
require "habitat"

module ActionController
  VERSION = "0.2.0"

  class Error < ::Exception
  end
end

require "./action-controller/errors"
require "./action-controller/base"
