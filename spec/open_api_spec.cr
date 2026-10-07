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

# routes the OpenAPI specs use to check the document is valid OpenAPI 3.0
class OpenAPIPaths < ActionController::Base
  # an untyped path param, read from the route params
  base "/openapi_paths/:tenant"

  getter tenant : String { route_params["tenant"] }

  struct CommaList
    def convert(raw : String)
      raw.split(',')
    end
  end

  @[AC::Route::GET("/eink/:item_id/?:expires_after")]
  def eink(item_id : String, expires_after : Int64? = nil) : String
    "#{tenant} #{item_id} #{expires_after}"
  end

  # optional segments are matched where they're written: `/mid/groups` and `/mid/5/groups`
  @[AC::Route::GET("/mid/?:user_id/groups")]
  def mid(user_id : Int64? = nil) : String
    "#{user_id}"
  end

  @[AC::Route::GET("/files/:id/*:file_name")]
  def file(id : String, file_name : String = "file") : String
    "#{id} #{file_name}"
  end

  @[AC::Route::GET("/search", converters: {tags: CommaList})]
  def search(
    @[AC::Param::Info(example: "10")]
    limit : Int32 = 10,
    @[AC::Param::Info(example: "true")]
    deep : Bool = false,
    @[AC::Param::Info(example: "zone-1,zone-2")]
    tags : Array(String) = [] of String,
    @[AC::Param::Info(example: "anything")]
    query : String? = nil,
  ) : String
    "#{limit} #{deep} #{tags} #{query}"
  end

  # two routes, the second needs a unique operationId that isn't `listing_2`'s
  @[AC::Route::GET("/listing")]
  @[AC::Route::GET("/listing/all")]
  def listing : String
    "listing"
  end

  @[AC::Route::GET("/listing_two")]
  def listing_2 : String
    "listing 2"
  end
end

describe ActionController::OpenAPI do
  it "extracts route descriptions" do
    result = ActionController::OpenAPI.extract_route_descriptions
    (result.size > 0).should be_true
  end

  it "generates openapi docs" do
    result = ActionController::OpenAPI.generate_open_api_docs("title", "version", description: "desc")
    result[:openapi].should eq "3.1.0"
    # includes the controllers defined in other spec files, after the server is required
    result[:paths].size.should eq 81
    result[:info][:description].should eq "desc"
  end

  it "generates OpenAPI 3.0.3 on request" do
    ActionController::OpenAPI.generate_open_api_docs({} of String => ActionController::OpenAPI::KlassDoc, "title", "version", openapi: "3.0.3")[:openapi].should eq "3.0.3"
    expect_raises(ArgumentError, /3\.1\.0 or 3\.0\.3/) do
      ActionController::OpenAPI.generate_open_api_docs({} of String => ActionController::OpenAPI::KlassDoc, "title", "version", openapi: "2.0")
    end
  end

  describe "OpenAPI 3.1" do
    item_docs = ActionController::OpenAPI::KlassDoc.new("OpenAPIRefs::Item", "an item in a list")
    docs = JSON.parse(ActionController::OpenAPI.generate_open_api_docs({"OpenAPIRefs::Item" => item_docs}, "title", "version").to_json)
    schemas = docs["components"]["schemas"]
    ref = ->(name : String) { JSON.parse({"$ref" => "#/components/schemas/OpenAPIRefs.#{name}"}.to_json) }

    it "uses null types rather than nullable" do
      docs["openapi"].should eq "3.1.0"
      docs.to_json.should_not contain %("nullable")
      schemas["OpenAPIRefs.List"]["properties"]["primary"].should eq JSON.parse({"anyOf" => [ref.call("Item"), {"type" => "null"}]}.to_json)
      docs["paths"]["/openapi_refs"]["get"]["parameters"][0]["schema"].should eq JSON.parse({"anyOf" => [ref.call("Status"), {"type" => "null"}]}.to_json)
    end

    it "keeps the doc comment and references of nested types" do
      schemas["OpenAPIRefs.Item"]["description"].should eq "an item in a list"
      schemas["OpenAPIRefs.List"]["properties"]["items"].should eq JSON.parse({"type" => "array", "items" => ref.call("Item")}.to_json)
    end

    it "types examples through null unions" do
      search = docs["paths"]["/openapi_paths/{tenant}/search"]["get"]["parameters"].as_a.to_h { |param| {param["name"].as_s, param} }
      search["limit"]["example"].should eq JSON::Any.new(10_i64)
      search["query"]["example"].should eq JSON::Any.new("anything")
    end
  end

  describe "nested types" do
    item_docs = ActionController::OpenAPI::KlassDoc.new("OpenAPIRefs::Item", "an item in a list")
    docs = JSON.parse(ActionController::OpenAPI.generate_open_api_docs({"OpenAPIRefs::Item" => item_docs}, "title", "version", openapi: "3.0.3").to_json)
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

  describe "OpenAPI validity" do
    docs = ActionController::OpenAPI.generate_open_api_docs({} of String => ActionController::OpenAPI::KlassDoc, "title", "version", openapi: "3.0.3")
    paths = JSON.parse(docs[:paths].to_json)
    params = ->(path : String) { paths[path]["get"]["parameters"].as_a.to_h { |param| {param["name"].as_s, param} } }

    it "writes response codes as strings" do
      yaml = YAML.parse(docs.to_yaml)
      yaml["paths"]["/openapi_paths/{tenant}/listing_two"]["get"]["responses"].as_h.keys.map(&.raw).should eq ["200"]
    end

    it "describes untyped path params as strings" do
      tenant = params.call("/openapi_paths/{tenant}/listing_two")["tenant"]
      tenant["in"].should eq "path"
      tenant["required"].should be_true
      tenant["schema"].should eq JSON.parse(%({"type":"string"}))
    end

    it "lists a path for each optional segment, as the router does" do
      absent = params.call("/openapi_paths/{tenant}/eink/{item_id}")
      absent.keys.should_not contain "expires_after"
      paths["/openapi_paths/{tenant}/eink/{item_id}"]["get"]["operationId"].should eq "OpenAPIPaths_eink_without_expires_after"

      present = params.call("/openapi_paths/{tenant}/eink/{item_id}/{expires_after}")
      present["expires_after"]["in"].should eq "path"
      present["expires_after"]["required"].should be_true
      paths["/openapi_paths/{tenant}/eink/{item_id}/{expires_after}"]["get"]["operationId"].should eq "OpenAPIPaths_eink"

      paths["/openapi_paths/{tenant}/mid/groups"]["get"]["operationId"].should eq "OpenAPIPaths_mid_without_user_id"
      paths["/openapi_paths/{tenant}/mid/{user_id}/groups"]["get"]["operationId"].should eq "OpenAPIPaths_mid"
      paths["/openapi_paths/{tenant}/mid/groups/{user_id}"]?.should be_nil

      params.call("/openapi_paths/{tenant}/files/{id}").keys.should_not contain "file_name"
      glob = params.call("/openapi_paths/{tenant}/files/{id}/{file_name}")["file_name"]
      glob["in"].should eq "path"
      glob["required"].should be_true
    end

    it "gives every operation a unique, URL safe operationId" do
      ids = paths.as_h.values.flat_map { |path| path.as_h.values.compact_map { |op| op.as_h?.try(&.["operationId"]?.try(&.as_s)) } }
      ids.uniq.size.should eq ids.size
      ids.each(&.should(match(/\A[A-Za-z0-9_.:~-]+\z/)))
      listing = ["/openapi_paths/{tenant}/listing", "/openapi_paths/{tenant}/listing/all", "/openapi_paths/{tenant}/listing_two"].map { |path| paths[path]["get"]["operationId"].as_s }
      listing.uniq.size.should eq 3
    end

    it "types examples by their schema" do
      search = params.call("/openapi_paths/{tenant}/search")
      search["limit"]["example"].should eq JSON::Any.new(10_i64)
      search["deep"]["example"].should eq JSON::Any.new(true)
      search["tags"]["example"].should eq JSON.parse(%(["zone-1","zone-2"]))
      search["query"]["example"].should eq JSON::Any.new("anything")
    end

    it "sends array query params as a single comma separated value" do
      tags = params.call("/openapi_paths/{tenant}/search")["tags"]
      tags["style"].should eq "form"
      tags["explode"].should eq false
      params.call("/openapi_paths/{tenant}/search")["limit"]["explode"]?.should be_nil
    end

    it "keeps optional path segments optional for MCP tools" do
      description = ActionController::MCPServer.generate_description({} of String => ActionController::OpenAPI::KlassDoc)
      toolbox = description.toolbox?("open_api_paths").should_not be_nil
      eink = toolbox.tools.find!(&.name.==("open_api_paths_eink"))
      eink.input_schema["required"].as_a.map(&.as_s).sort!.should eq ["item_id", "tenant"]
      eink.input_schema["properties"]["expires_after"]["examples"]?.should be_nil
      file = toolbox.tools.find!(&.name.==("open_api_paths_file"))
      file.input_schema["required"].as_a.map(&.as_s).sort!.should eq ["id", "tenant"]
      search = toolbox.tools.find!(&.name.==("open_api_paths_search"))
      search.input_schema["properties"]["limit"]["examples"].should eq JSON.parse("[10]")
    end
  end
end
