require "./spec_helper"

describe ActionController::OpenAPI do
  it "extracts route descriptions" do
    result = ActionController::OpenAPI.extract_route_descriptions
    (result.size > 0).should be_true
  end
end
