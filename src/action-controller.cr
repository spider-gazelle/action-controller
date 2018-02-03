require "logger"
require "habitat"

module ActionController
  VERSION = "0.1.2"

  class Error < ::Exception
  end
end

require "./action-controller/errors"
require "./action-controller/base"
