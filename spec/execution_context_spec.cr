require "./spec_helper"

# These specs exercise the public API of `ActionController::ExecutionContext`.
# They are flag-agnostic: without `-Dexecution_context` the configuration is a
# no-op and `serialize_response` runs the block inline, with the flag the block
# is piped to the response execution context. The observable behaviour asserted
# here holds in both cases.
describe ActionController::ExecutionContext do
  it "exposes configurable response parallelism" do
    ActionController::ExecutionContext.response_parallelism = 9

    # under the flag the setter updates the configuration, as a no-op it is
    # ignored and the default is returned - either way the API is callable
    {% if flag?(:execution_context) %}
      ActionController::ExecutionContext.response_parallelism.should eq(9)
    {% else %}
      ActionController::ExecutionContext.response_parallelism.should eq(4)
    {% end %}
  end

  it "runs the serialisation block" do
    ran = false
    ActionController::ExecutionContext.serialize_response { ran = true }
    ran.should be_true
  end

  it "propagates errors raised while serialising" do
    expect_raises(Exception, "boom") do
      ActionController::ExecutionContext.serialize_response { raise "boom" }
    end
  end
end
