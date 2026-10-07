require "../../src/action-controller"
require "../../src/action-controller/server"
require "../../src/action-controller/mcp"

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
  base "/excluded"

  @[AC::Route::GET("/")]
  def index : String
    "excluded"
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
  puts "configured routing, OpenAPI and MCP"
  exit
end

AC::Server.compose(ConfiguredApp)
