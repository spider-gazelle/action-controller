class ActionController::FileHandler < ::HTTP::StaticFileHandler
  MIME_TYPES = {
    ".txt"      => "text/plain",
    ".htm"      => "text/html",
    ".html"     => "text/html",
    ".css"      => "text/css",
    ".js"       => "application/javascript",
    ".png"      => "image/png",
    ".gif"      => "image/gif",
    ".jfif"     => "image/jpeg",
    ".jpe"      => "image/jpeg",
    ".jpeg"     => "image/jpeg",
    ".jpg"      => "image/jpeg",
    ".webp"     => "image/webp",
    ".appcache" => "text/cache-manifest",
    ".ico"      => "image/x-icon",
    ".json"     => "application/json",
    ".svg"      => "image/svg+xml",
    ".woff"     => "font/woff",
    ".woff2"    => "font/woff2",
    ".ttf"      => "font/ttf",
    ".otf"      => "font/opentype",
  } of String => String

  # Allow additional mime types to be configured
  private def mime_type(path)
    mime = MIME_TYPES[File.extname(path)]?
    mime || "application/octet-stream"
  end
end
