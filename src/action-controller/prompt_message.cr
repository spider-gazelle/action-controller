require "json"
require "yaml"

# a message returned by an MCP prompt, see `ActionController::MCP`
#
# ```
# # starts a code review conversation
# @[AC::MCP(prompt: true)]
# def review(id : Int64) : Array(AC::PromptMessage)
#   [
#     AC::PromptMessage.user("Please review pull request #{id}"),
#     AC::PromptMessage.assistant("Which aspects should I focus on?"),
#   ]
# end
# ```
struct ActionController::PromptMessage
  include JSON::Serializable
  include YAML::Serializable

  enum Role
    User
    Assistant
  end

  getter role : Role
  getter text : String

  def initialize(@text : String, @role : Role = Role::User)
  end

  def self.user(text : String) : PromptMessage
    new(text, Role::User)
  end

  def self.assistant(text : String) : PromptMessage
    new(text, Role::Assistant)
  end
end
