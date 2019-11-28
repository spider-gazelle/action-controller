require "./spec_helper"

describe ActionController::ErrorHandler do
  it "should initialize an error handler" do
    prod = ActionController::ErrorHandler.new(false, ["X-Request-ID"])
    dev = ActionController::ErrorHandler.new(true, ["X-Request-ID"])
  end
end
