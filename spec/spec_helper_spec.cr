require "./spec_helper"

alias UserRes = Array(NamedTuple(name: String, state: String))

describe "Context" do
  it "can spec via direct instansiation" do
    testable_controller = Filtering.spec_instance
    testable_controller.other_route("some_input").should eq "some_input"
  end

  it "should spec #index the most verbose way" do
    # Instantiate the controller
    users_controller = Users.spec_instance(HTTP::Request.new("GET", Users.base_route, headers: HTTP::Headers{
      "Authorization" => "X",
    }))

    # Call the method
    users_controller.index

    # Expectation
    response = users_controller.response
    response.status_code.should eq 200
    response.output.rewind
    parsed = UserRes.from_json(response.output)
    parsed.size.should eq(5)
    parsed.should contain({name: "James", state: "NSW"})
  end
end
