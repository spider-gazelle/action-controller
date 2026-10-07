require "base64"
require "mime"

module ActionController::MCPServer
  # :nodoc:
  # resolves the `src` of `@[AC::Icon]` and `MCPServer.icon` icons when they're sent:
  #
  # * `https:` and `data:` URLs are used as is
  # * a file in `MCPServer.ui_base` is sent as a `data:` URL
  # * anything else is a path on the current host, `https://<host>/<src>`
  #
  # every other icon field is passed through as is
  module Icons
    extend self

    @@data = {} of String => Tuple(Time, String)
    @@lock = Mutex.new

    # writes the `icons` field, if there are any
    def to_json(json : JSON::Builder, icons : Array(JSON::Any)?, host : String?) : Nil
      return if icons.nil? || icons.empty?
      json.field "icons" do
        json.array { icons.each { |icon| resolve(icon, host).to_json(json) } }
      end
    end

    def resolve(icon : JSON::Any, host : String?) : JSON::Any
      return icon unless (fields = icon.as_h?) && (src = fields["src"]?.try(&.as_s?))
      resolved = resolve_src(src, host)
      return icon if resolved == src

      fields = fields.dup
      fields["src"] = JSON::Any.new(resolved)
      JSON::Any.new(fields)
    end

    def resolve_src(src : String, host : String?) : String
      return src if src.starts_with?("https:") || src.starts_with?("data:")
      if file = file?(src)
        return data_url(file)
      end
      path = src.starts_with?('/') ? src : "/#{src}"
      host ? "https://#{host}#{path}" : path
    end

    # the icon file in `ui_base`, never outside it
    private def file?(src : String) : String?
      return unless base = MCPServer.ui_base
      path = src.lchop('/')
      return if path.empty? || path.split('/').includes?("..")

      root = File.expand_path(base)
      file = File.expand_path(path, root)
      return unless file.starts_with?(root + File::SEPARATOR)
      file if File.file?(file)
    end

    # cached until the file changes
    private def data_url(file : String) : String
      modified = File.info(file).modification_time
      @@lock.synchronize do
        cached = @@data[file]?
        return cached[1] if cached && cached[0] == modified

        mime = MIME.from_filename?(file) || "application/octet-stream"
        url = "data:#{mime.split(';').first};base64,#{Base64.strict_encode(File.read(file))}"
        @@data[file] = {modified, url}
        url
      end
    end
  end
end
