require "logger"
require "habitat"

module ActionController
  VERSION = "0.1.0"

  class Error < ::Exception
  end
end

require "./action-controller/base"
