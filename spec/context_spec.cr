BASE = Users.base_route
alias UserRes = Array(NamedTuple(name: String, state: String))

describe "Context" do
  it "should spec #index the most verbose way" do
    # Instantiate the controller
    body_io = IO::Memory.new
    ctx = context("GET", BASE, body: body_io, authorization: "X")
    ctx.route_params = {"verbose" => "true"}
    ctx.response.output = IO::Memory.new
    Users.new(ctx).index

    # Expectation
    ctx.response.status_code.should eq 200
    ctx.response.output.rewind
    parsed = UserRes.from_json(ctx.response.output)
    parsed.size.should eq(5)
    parsed.should contain({name: "James", state: "NSW"})
  end

  it "should spec #index without specifying body, output IO::Memory" do
    # Instantiate the controller
    res = context(method: "GET", route: BASE, route_params: {"verbose" => "true"}, headers: {"Authorization" => "X"}) { |i| Users.new(i).index }

    # Expectation
    res.status_code.should eq 200
    parsed = UserRes.from_json(res.output)
    parsed.size.should eq(5)
    parsed.should contain({name: "James", state: "NSW"})
  end

  it "should spec #index without specifying body, output IO::Memory, instantiating controller in each block but have Controller module included directly" do
    # Instantiate the controller
    res = Users.context(method: "GET", route: BASE, route_params: {"verbose" => "true"}, headers: {"Authorization" => "X"}, &.index)

    # Expectation
    res.status_code.should eq 200
    parsed = UserRes.from_json(res.output)
    parsed.size.should eq(5)
    parsed.should contain({name: "James", state: "NSW"})
  end
end
