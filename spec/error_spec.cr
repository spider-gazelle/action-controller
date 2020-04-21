require "./spec_helper"

describe ActionController::ErrorHandler do
  it "should initialize a production error handler" do
    ActionController::ErrorHandler.new(production: true, persist_headers: ["X-Request-ID"])
  end

  it "should initiaze a development error handler" do
    ActionController::ErrorHandler.new(production: false, persist_headers: ["X-Request-ID"])
  end
end
