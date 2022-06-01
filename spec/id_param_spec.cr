require "./spec_helper"

describe "template responses" do
  client = AC::SpecHelper.client

  it "should use a custom ID param for default routes" do
    result = client.get("/container/42")
    result.body.should eq("got: 42")
  end

  it "should allow for deeply nested routes" do
    result = client.get("/container/42/objects/8")
    result.body.should eq("8 in 42")
  end
end
