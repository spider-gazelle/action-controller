require "digest/sha256"

module ActionController::MCPServer
  # OAuth 2.0 Protected Resource Metadata ([RFC 9728](https://www.rfc-editor.org/rfc/rfc9728)),
  # tells MCP clients where to obtain access tokens
  struct ResourceMetadata
    # the OAuth authorization servers that issue tokens for this resource
    getter authorization_servers : Array(String)

    # the scopes MCP clients should request
    getter scopes_supported : Array(String)?

    # human readable documentation for developers
    getter resource_documentation : String?

    def initialize(@authorization_servers, @scopes_supported = nil, @resource_documentation = nil)
    end

    # :nodoc:
    def to_json(resource : String) : String
      JSON.build do |json|
        json.object do
          json.field "resource", resource
          json.field "authorization_servers", authorization_servers
          json.field "scopes_supported", scopes_supported if scopes_supported
          json.field "bearer_methods_supported", {"header"}
          json.field "resource_documentation", resource_documentation if resource_documentation
        end
      end
    end
  end

  # raised when a tool call is rejected by the application with a 401
  class Unauthorized < Exception
  end

  # caches successful authentication checks, keyed by a fingerprint of the
  # forwarded credentials, so the application isn't consulted on every message
  class AuthCache
    MAX_ENTRIES = 10_000

    @entries = {} of String => Time
    @lock = Mutex.new

    # returns the fingerprint of the credentials in the request, `nil` if there are none
    def self.fingerprint(request : HTTP::Request) : String?
      credentials = String.build do |str|
        MCPServer.forward_headers.each do |header|
          next unless values = request.headers.get?(header)
          str << header << ':' << values.join(',') << '\n'
        end
      end
      return if credentials.empty?
      Digest::SHA256.hexdigest("#{request.headers["Host"]?}\n#{credentials}")
    end

    def valid?(fingerprint : String) : Bool
      @lock.synchronize do
        if expires = @entries[fingerprint]?
          return true if expires > Time.utc
          @entries.delete(fingerprint)
        end
        false
      end
    end

    def store(fingerprint : String, ttl : Time::Span) : Nil
      return unless ttl.positive?
      now = Time.utc
      @lock.synchronize do
        if @entries.size >= MAX_ENTRIES
          @entries.reject! { |_key, expires| expires <= now }
          @entries.clear if @entries.size >= MAX_ENTRIES
        end
        @entries[fingerprint] = now + ttl
      end
    end

    def delete(fingerprint : String) : Nil
      @lock.synchronize { @entries.delete(fingerprint) }
    end

    def clear : Nil
      @lock.synchronize { @entries.clear }
    end
  end
end
