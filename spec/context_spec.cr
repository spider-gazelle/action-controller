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
    parsed = UserRes.from_json(ctx.response.output.to_s)
    parsed.size.should eq(5)
    parsed.should contain({name: "James", state: "NSW"})
  end

  it "should spec #index without specifying body, output IO::Memory" do
    # Instantiate the controller
    res = context(method: "GET", route: BASE, route_params: {"verbose" => "true"}, headers: {"Authorization" => "X"}) { |i| Users.new(i).index }

    # Expectation
    res.status_code.should eq 200
    parsed = UserRes.from_json(res.body)
    parsed.size.should eq(5)
    parsed.should contain({name: "James", state: "NSW"})
  end

  it "should spec #index without specifying body, output IO::Memory, instantiating controller in each block" do
    # Instantiate the controller
    res = Controller(Users).context(method: "GET", route: BASE, route_params: {"verbose" => "true"}, headers: {"Authorization" => "X"}, &.index)

    # Expectation
    res.status_code.should eq 200
    parsed = UserRes.from_json(res.body)
    parsed.size.should eq(5)
    parsed.should contain({name: "James", state: "NSW"})
  end

  it "should spec #index without specifying body, output IO::Memory, instantiating controller in each block, and deserialise output into defined type" do
    # Instantiate the controller
    res = ControllerModel(Users, UserRes).context(method: "GET", route: BASE, route_params: {"verbose" => "true"}, headers: {"Authorization" => "X"}, &.index)

    # Expectation
    res.status_code.should eq 200
    res.body.size.should eq(5)
    res.body.as(UserRes).should contain({name: "James", state: "NSW"})
  end
end
