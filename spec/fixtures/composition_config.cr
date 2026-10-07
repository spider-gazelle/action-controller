require "../../src/action-controller"
require "../../src/action-controller/server"
require "../../src/action-controller/mcp"
require "../../src/action-controller/spec_helper"

abstract class ConfiguredApp < AC::Base
end

class ConfiguredPage < ConfiguredApp
  base "/configured"

  @[AC::Route::GET("/")]
  def index : String
    "configured"
  end
end

class ExcludedPage < AC::Base
  # Identical public paths must keep separate HTTP and catalog definitions.
  base "/configured"

  @[AC::Route::GET("/")]
  def index(count : Int32 = 2) : Int32
    count
  end
end

# The template handles CLI options before its config.cr initialization runs.
# This verifies that a later composition declaration applies to earlier calls.
if ARGV.includes?("--check")
  composition = AC::Composition.default
  raise "wrong route selection" unless AC::Server.routes.map(&.[3]) == ["/configured"]
  docs = AC::OpenAPI.generate_open_api_docs({} of String => AC::OpenAPI::KlassDoc, "test", "1")
  raise "wrong OpenAPI selection" unless docs[:paths].keys == ["/configured"]
  description = AC::MCPServer.generate_description(docs: false)
  raise "wrong MCP selection" unless description.toolboxes.flat_map(&.tools).map(&.path) == ["/configured"]
  raise "wrong default handler" unless HotTopic.new(composition).get("/configured").body == %q("configured")
  excluded = ExcludedPage.handler
  raise "handler definitions collided" unless HotTopic.new(excluded).get("/configured?count=3").body == "3"
  excluded_docs = AC::OpenAPI.generate_open_api_docs({} of String => AC::OpenAPI::KlassDoc, "excluded", "1", composition: excluded)
  selected_params = docs[:paths]["/configured"].get.try(&.parameters) || [] of AC::OpenAPI::Parameter
  excluded_params = excluded_docs[:paths]["/configured"].get.try(&.parameters) || [] of AC::OpenAPI::Parameter
  raise "OpenAPI definitions collided" unless selected_params.empty? && excluded_params.map(&.name) == ["count"]
  excluded_description = AC::MCPServer.generate_description(docs: false, composition: excluded)
  selected_tool = description.toolboxes.first.tools.first
  excluded_tool = excluded_description.toolboxes.first.tools.first
  raise "MCP definitions collided" unless selected_tool.input_schema["properties"].as_h.empty? && excluded_tool.input_schema["properties"].as_h.has_key?("count")
  puts "configured routing, OpenAPI and MCP"
  exit
end

AC::Server.compose(ConfiguredApp)
