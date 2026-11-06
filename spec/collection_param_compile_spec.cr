require "spec"

# an Array or Set param is read from repetitions of a query (or form) name,
# anything else is a compile time error naming the parameter
describe "collection param compile errors" do
  {
    "path_param"          => {"an Array on a path segment", "tag : Array(String) can only be a query parameter"},
    "optional_path_param" => {"an Array on an optional path segment", "tag : Array(String) can only be a query parameter"},
    "header_param"        => {"an Array header", "tag : Array(String) can only be a query parameter"},
    "nested_param"        => {"a collection of collections", "tag : Array(Set(String)) has collections for elements, which a query parameter can't hold"},
  }.each do |flag, (description, message)|
    it "rejects #{description}" do
      errors = IO::Memory.new
      status = Process.run("crystal", ["build", "--no-codegen", "-D#{flag}", File.join(__DIR__, "fixtures", "collection_param_errors.cr")], output: Process::Redirect::Close, error: errors)
      status.success?.should be_false
      errors.to_s.should contain "CollectionParams#index: #{message}"
    end
  end
end
