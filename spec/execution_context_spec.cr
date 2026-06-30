require "./spec_helper"

# named context used by the specs below; with the flag it builds a real context,
# without it this only records the name so the controller routes still validate.
ActionController::ExecutionContext.define "spec-ctx", parallelism: 2

# records the execution context the most recent action ran in
SPEC_ACTION_CONTEXT = [] of String

# controller-wide binding + a per-route override. Exercises the macro wiring in
# both flag modes (responses are identical either way).
class SpecContextController < ActionController::Base
  base "/spec_context"
  execution_context "spec-ctx"

  @[AC::Route::GET("/")]
  def index : NamedTuple(ok: Bool)
    {% if flag?(:execution_context) %}SPEC_ACTION_CONTEXT << Fiber.current.execution_context.name{% end %}
    {ok: true}
  end

  @[AC::Route::GET("/override", execution_context: "spec-ctx")]
  def override : Array(Int32)
    {% if flag?(:execution_context) %}SPEC_ACTION_CONTEXT << Fiber.current.execution_context.name{% end %}
    [1, 2, 3]
  end
end

# These specs are flag-agnostic. Without `-Dexecution_context` the configuration
# is a no-op and `offload` runs the block inline; with the flag the block is piped
# to the relevant execution context. The asserted behaviour holds in both cases.
# Context-specific assertions are guarded by the flag.
describe ActionController::ExecutionContext do
  client = AC::SpecHelper.client

  it "exposes configurable response parallelism" do
    ActionController::ExecutionContext.response_parallelism = 9

    {% if flag?(:execution_context) %}
      ActionController::ExecutionContext.response_parallelism.should eq(9)
    {% else %}
      ActionController::ExecutionContext.response_parallelism.should eq(4)
    {% end %}
  end

  it "runs the serialisation block" do
    ran = false
    ActionController::ExecutionContext.offload { ran = true }
    ran.should be_true
  end

  it "propagates errors raised while serialising" do
    expect_raises(Exception, "boom") do
      ActionController::ExecutionContext.offload { raise "boom" }
    end
  end

  it "serves controller and per-route bound responses" do
    client.get("/spec_context/").body.should eq(%({"ok":true}))
    client.get("/spec_context/override").body.should eq("[1,2,3]")
  end

  it "skips the body (and any context) for HEAD requests" do
    result = client.head("/spec_context/")
    result.status_code.should eq(200)
    result.body.should eq("")
  end

  {% if flag?(:execution_context) %}
    it "lazily creates a distinct, memoized named context" do
      ctx = ActionController::ExecutionContext.context_spec_ctx
      ctx.should be_a(::Fiber::ExecutionContext::Parallel)
      ctx.name.should eq("spec-ctx")
      # memoized - same instance every call, and distinct from the default
      ctx.same?(ActionController::ExecutionContext.context_spec_ctx).should be_true
      ctx.same?(ActionController::ExecutionContext.response_context).should be_false
    end

    it "serialises in the supplied named context" do
      ran_in = nil.as(String?)
      ActionController::ExecutionContext.offload(ActionController::ExecutionContext.context_spec_ctx) do
        ran_in = Fiber.current.execution_context.name
      end
      ran_in.should eq("spec-ctx")
    end

    it "runs the whole request (action included) in the bound context" do
      SPEC_ACTION_CONTEXT.clear
      client.get("/spec_context/")
      SPEC_ACTION_CONTEXT.last.should eq("spec-ctx")

      SPEC_ACTION_CONTEXT.clear
      client.get("/spec_context/override")
      SPEC_ACTION_CONTEXT.last.should eq("spec-ctx")
    end
  {% end %}
end
