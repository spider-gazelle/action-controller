require "mime"

# This is deprecated in favour of the built in MIME store and handlers
# this is updated to provide compatibility but will be removed in the future
class ActionController::FileHandler < ::HTTP::StaticFileHandler
  class MIME_TYPES
    def self.[]=(key, value)
      ::MIME.register(key, value)
    end
  end
end
