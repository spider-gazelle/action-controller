require "spec"

describe "composition configuration" do
  it "selects routing and catalogs before config.cr initialization" do
    output = IO::Memory.new
    errors = IO::Memory.new
    status = Process.run("crystal", ["run", File.join(__DIR__, "fixtures", "composition_config.cr"), "--error-trace", "--", "--check"], output: output, error: errors)
    fail errors.to_s unless status.success?
    output.to_s.should contain "configured routing, OpenAPI and MCP"
  end
end
