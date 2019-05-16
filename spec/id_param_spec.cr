require "./spec_helper"

describe "template responses" do
  with_server do
    it "should use a custom ID param for default routes" do
      result = curl("GET", "/container/42")
      result.body.should eq("got: 42")
    end

    it "should allow for deeply nested routes" do
      result = curl("GET", "/container/42/objects/8")
      result.body.should eq("8 in 42")
    end
  end
end
