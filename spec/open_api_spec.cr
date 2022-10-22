require "./spec_helper"

describe ActionController::OpenAPI do
  it "extracts route descriptions" do
    result = ActionController::OpenAPI.extract_route_descriptions
    (result.size > 0).should be_true
  end

  it "generates openapi docs" do
    result = ActionController::OpenAPI.generate_open_api_docs("title", "version", description: "desc")
    result[:openapi].should eq "3.0.3"
    result[:paths].size.should eq 19
    result[:info][:description].should eq "desc"
  end
end
