require "./spec_helper"

describe ActionController::ErrorHandler do
  it "should initialize a production error handler" do
    ActionController::ErrorHandler.new(development: false, persist_headers: ["X-Request-ID"])
  end

  it "should initiaze a development error handler" do
    ActionController::ErrorHandler.new(development: true, persist_headers: ["X-Request-ID"])
  end
end
