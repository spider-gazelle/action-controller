require "digest/sha256"

module ActionController::MCPServer
  # Content security policy domains for a card, see `UIMeta`
  struct UICSP
    include JSON::Serializable

    # origins the card can connect to (`fetch`, websockets)
    @[JSON::Field(key: "connectDomains")]
    getter connect_domains : Array(String)?

    # origins the card can load scripts, styles, images, fonts and media from
    @[JSON::Field(key: "resourceDomains")]
    getter resource_domains : Array(String)?

    # origins the card can embed in frames
    @[JSON::Field(key: "frameDomains")]
    getter frame_domains : Array(String)?

    # origins allowed as the document base URI
    @[JSON::Field(key: "baseUriDomains")]
    getter base_uri_domains : Array(String)?

    def initialize(@connect_domains = nil, @resource_domains = nil, @frame_domains = nil, @base_uri_domains = nil)
    end
  end

  # How hosts render a card, the `_meta.ui` of an MCP Apps resource.
  # Set a default with `MCPServer.ui_meta`, or override it for a card with a
  # `<card>.meta.json` file next to it, i.e. `bookings/card.meta.json`
  struct UIMeta
    include JSON::Serializable

    # domains the card needs, by default it can't load external resources
    getter csp : UICSP?

    # browser permissions requested, i.e. `{"camera": {}, "clipboardWrite": {}}`
    getter permissions : Hash(String, JSON::Any)?

    # a dedicated sandbox origin, host specific
    getter domain : String?

    # whether the host should draw a border around the card
    @[JSON::Field(key: "prefersBorder")]
    getter prefers_border : Bool?

    def initialize(@csp = nil, @permissions = nil, @domain = nil, @prefers_border = nil)
    end
  end

  # :nodoc:
  # resolves `ui://` card resources to the files in `MCPServer.ui_base`
  module UI
    extend self

    EXTENSION = "io.modelcontextprotocol/ui"
    MIME_TYPE = "text/html;profile=mcp-app"
    SCHEME    = "ui://"

    @@versions = {} of String => Tuple(Time, String)
    @@lock = Mutex.new

    # the URI without its version, i.e. `ui://bookings/card.html`
    def unversioned(uri : String) : String
      uri.split('?', 2).first
    end

    # the file for a card URI, `nil` if it isn't an existing .html file in `ui_base`
    def resolve(uri : String) : String?
      return unless base = MCPServer.ui_base
      return unless uri.starts_with?(SCHEME)
      path = unversioned(uri)[SCHEME.size..]
      return if path.empty? || path.starts_with?('/') || path.split('/').includes?("..") || !path.ends_with?(".html")

      root = File.expand_path(base)
      file = File.expand_path(path, root)
      return unless file.starts_with?(root + File::SEPARATOR)
      file if File.file?(file)
    end

    # the URI with a version derived from the card's content, so hosts don't render a
    # stale cached card after it changes. Returned as is if the card can't be found
    def versioned(uri : String) : String
      return uri unless file = resolve(uri)
      modified = File.info(file).modification_time
      version = @@lock.synchronize do
        cached = @@versions[file]?
        if cached && cached[0] == modified
          cached[1]
        else
          hash = Digest::SHA256.hexdigest(File.read(file))[0, 12]
          @@versions[file] = {modified, hash}
          hash
        end
      end
      "#{unversioned(uri)}?v=#{version}"
    end

    # the card's `_meta.ui`, from its `.meta.json` sidecar or `MCPServer.ui_meta`
    def meta(file : String) : UIMeta?
      sidecar = file.rchop(".html") + ".meta.json"
      return MCPServer.ui_meta unless File.file?(sidecar)
      UIMeta.from_json(File.read(sidecar))
    rescue error : JSON::ParseException
      Log.warn { "invalid MCP UI metadata #{sidecar}: #{error.message}" }
      MCPServer.ui_meta
    end

    # the `resources/read` result for a card
    def read(uri : String) : String?
      return unless file = resolve(uri)
      html = File.read(file)
      ui_meta = meta(file)
      JSON.build do |json|
        json.object do
          json.field "contents" do
            json.array do
              json.object do
                json.field "uri", uri
                json.field "mimeType", MIME_TYPE
                json.field "text", html
                if ui_meta
                  json.field "_meta" do
                    json.object { json.field "ui", ui_meta }
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
