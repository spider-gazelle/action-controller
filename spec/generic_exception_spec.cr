require "./spec_helper"

describe "exception handlers for generic exceptions" do
  client = AC::SpecHelper.client

  it "handles every instantiation of an uninstantiated generic" do
    result = client.get("/generic_errors/400")
    result.status_code.should eq 400
    result.body.should eq "handled 400: bad request"

    result = client.get("/generic_errors/401")
    result.status_code.should eq 400
    result.body.should eq "handled 401: unauthorized"

    client.get("/generic_errors/200").body.should eq "no error"
  end

  it "handles a specific instantiation only" do
    result = client.get("/specific_generic_error/418")
    result.status_code.should eq 418
    result.body.should eq "short and stout"

    expect_raises(GenericError(500)) { client.get("/specific_generic_error/500") }
  end

  it "documents the handler responses in OpenAPI" do
    docs = ActionController::OpenAPI.generate_open_api_docs("title", "version")
    generic = docs[:paths]["/generic_errors/{code}"].get.should_not be_nil
    generic.responses.keys.should contain "400"
    specific = docs[:paths]["/specific_generic_error/{code}"].get.should_not be_nil
    specific.responses.keys.should contain "418"
  end
end
