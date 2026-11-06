require "spec"

# params the route builder can't bind are compile time errors naming them:
# collections outside the query, and a body typed as an IO subclass
describe "param compile errors" do
  {
    "path_param"          => {"an Array on a path segment", "tag : Array(String) can only be a query parameter"},
    "optional_path_param" => {"an Array on an optional path segment", "tag : Array(String) can only be a query parameter"},
    "header_param"        => {"an Array header", "tag : Array(String) can only be a query parameter"},
    "nested_param"        => {"a collection of collections", "tag : Array(Set(String)) has collections for elements, which a query parameter can't hold"},
    "io_subclass_body"    => {"a body typed as an IO subclass", "file : IO::Memory, a raw body is typed IO or Bytes"},
    "byte_format_unused"  => {"byte_format: with nothing IO serialisable", "byte_format: needs an IO serialisable body or response"},
  }.each do |flag, (description, message)|
    it "rejects #{description}" do
      errors = IO::Memory.new
      status = Process.run("crystal", ["build", "--no-codegen", "-D#{flag}", File.join(__DIR__, "fixtures", "param_errors.cr")], output: Process::Redirect::Close, error: errors)
      status.success?.should be_false
      errors.to_s.should contain "CollectionParams#index: #{message}"
    end
  end
end
