require "./spec_helper"
require "../src/action-controller/mcp"

# `Tagged(OpenAPIP::OpenAPIQ, OpenAPIR)` and `Tagged(OpenAPIP, OpenAPIQ::OpenAPIR)` are distinct
# types whose names only differ by separators
module OpenAPIP
  module OpenAPIQ
  end
end

module OpenAPIQ
  module OpenAPIR
  end
end

module OpenAPIR
end

# lists, used by the OpenAPI specs to check nested types are referenced
class OpenAPIRefs < ActionController::Base
  base "/openapi_refs"

  enum Status
    Active
    Archived
  end

  # an item in a list
  struct Item
    include JSON::Serializable
    include YAML::Serializable
    getter content : String
    getter status : Status
  end

  struct List
    include JSON::Serializable
    include YAML::Serializable
    getter items : Array(Item)
    getter primary : Item?
  end

  struct Page(T)
    include JSON::Serializable
    getter page : Array(T)
    getter total : Int32
  end

  class Tree
    include JSON::Serializable
    getter name : String
    getter children : Array(Tree)
  end

  struct Tagged(T, U)
    include JSON::Serializable
    getter value : Int32
  end

  @[AC::Route::GET("/tagged/left")]
  def tagged_left : Tagged(OpenAPIP::OpenAPIQ, OpenAPIR)
    raise "not implemented"
  end

  @[AC::Route::GET("/tagged/right")]
  def tagged_right : Tagged(OpenAPIP, OpenAPIQ::OpenAPIR)
    raise "not implemented"
  end

  @[AC::Route::GET("/")]
  def index(status : Status? = nil) : Page(List)
    raise "not implemented"
  end

  @[AC::Route::GET("/:id")]
  def show(id : String) : List
    raise "not implemented"
  end

  @[AC::Route::POST("/", body: :list)]
  def create(list : List) : Array(Item)
    list.items
  end

  @[AC::Route::GET("/tree")]
  def tree : Tree
    raise "not implemented"
  end
end

describe ActionController::OpenAPI do
  it "extracts route descriptions" do
    result = ActionController::OpenAPI.extract_route_descriptions
    (result.size > 0).should be_true
  end

  it "generates openapi docs" do
    result = ActionController::OpenAPI.generate_open_api_docs("title", "version", description: "desc")
    result[:openapi].should eq "3.0.3"
    # includes the controllers defined in other spec files, after the server is required
    result[:paths].size.should eq 66
    result[:info][:description].should eq "desc"
  end

  describe "nested types" do
    item_docs = ActionController::OpenAPI::KlassDoc.new("OpenAPIRefs::Item", "an item in a list")
    docs = JSON.parse(ActionController::OpenAPI.generate_open_api_docs({"OpenAPIRefs::Item" => item_docs}, "title", "version").to_json)
    schemas = docs["components"]["schemas"]
    ref = ->(name : String) { JSON.parse({"$ref" => "#/components/schemas/OpenAPIRefs.#{name}"}.to_json) }

    it "defines nested types once, as components" do
      schemas["OpenAPIRefs.Item"].should eq JSON.parse({
        "type"       => "object",
        "properties" => {
          "content" => {"type" => "string"},
          "status"  => {"$ref" => "#/components/schemas/OpenAPIRefs.Status"},
        },
        "required"    => ["content", "status"],
        "description" => "an item in a list",
      }.to_json)
      schemas["OpenAPIRefs.Status"].should eq JSON.parse({"type" => "string", "enum" => ["active", "archived"]}.to_json)
    end

    it "references nested types" do
      list = schemas["OpenAPIRefs.List"]["properties"]
      list["items"].should eq JSON.parse({"type" => "array", "items" => ref.call("Item")}.to_json)
      list["primary"].should eq JSON.parse({"allOf" => [ref.call("Item")], "type" => "object", "nullable" => true}.to_json)

      schemas["OpenAPIRefs.Page-oOpenAPIRefs.List-c"]["properties"]["page"]["items"].should eq ref.call("List")
    end

    it "references route types" do
      paths = docs["paths"]
      paths["/openapi_refs"]["get"]["parameters"][0]["schema"].should eq JSON.parse({"allOf" => [ref.call("Status")], "type" => "string", "nullable" => true}.to_json)
      paths["/openapi_refs"]["get"]["responses"]["200"]["content"]["application/json"]["schema"].should eq ref.call("Page-oOpenAPIRefs.List-c")
      paths["/openapi_refs"]["post"]["requestBody"]["content"]["application/json"]["schema"].should eq ref.call("List")
      paths["/openapi_refs"]["post"]["responses"]["200"]["content"]["application/json"]["schema"].should eq JSON.parse({"type" => "array", "items" => ref.call("Item")}.to_json)
    end

    it "gives distinct types distinct names" do
      left = ref.call("Tagged-oOpenAPIP.OpenAPIQ-nOpenAPIR-c")
      right = ref.call("Tagged-oOpenAPIP-nOpenAPIQ.OpenAPIR-c")
      docs["paths"]["/openapi_refs/tagged/left"]["get"]["responses"]["200"]["content"]["application/json"]["schema"].should eq left
      docs["paths"]["/openapi_refs/tagged/right"]["get"]["responses"]["200"]["content"]["application/json"]["schema"].should eq right
      schemas["OpenAPIRefs.Tagged-oOpenAPIP.OpenAPIQ-nOpenAPIR-c"]?.should_not be_nil
      schemas["OpenAPIRefs.Tagged-oOpenAPIP-nOpenAPIQ.OpenAPIR-c"]?.should_not be_nil
    end

    it "supports self referencing types" do
      schemas["OpenAPIRefs.Tree"]["properties"]["children"].should eq JSON.parse({"type" => "array", "items" => ref.call("Tree")}.to_json)
    end

    it "includes the referenced definitions in MCP tool schemas" do
      description = ActionController::MCPServer.generate_description({} of String => ActionController::OpenAPI::KlassDoc)
      toolbox = description.toolbox?("open_api_refs").should_not be_nil
      tools = toolbox.tools
      create = tools.find!(&.name.==("open_api_refs_create"))
      create.input_schema["properties"]["body"].should eq JSON.parse({"$ref" => "#/$defs/OpenAPIRefs.List"}.to_json)
      create.input_schema["$defs"].as_h.keys.sort!.should eq ["OpenAPIRefs.Item", "OpenAPIRefs.List", "OpenAPIRefs.Status"]
    end
  end
end
