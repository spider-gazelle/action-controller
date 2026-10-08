require "mime/media_type"

# :nodoc:
module ActionController::Support
  # ports `ActionController::Server` accepts TLS connections on
  class_getter tls_ports : Set(Int32) = Set(Int32).new

  # returns `:https` or `:http`.
  #
  # proxy headers (`X-Forwarded-Proto`, `Forwarded`) describe the client's protocol, so
  # take precedence. Otherwise a connection to a port the server bound with TLS is `:https`
  def self.request_protocol(request)
    if proto = request.headers["X-Forwarded-Proto"]?
      return proto =~ /https/i ? :https : :http
    end
    if forwarded = request.headers["Forwarded"]?
      return forwarded =~ /proto=https/i ? :https : :http if forwarded =~ /proto=/i
    end
    address = request.local_address
    return :https if address.is_a?(Socket::IPAddress) && tls_ports.includes?(address.port)
    :http
  end

  def self.redirect_to_https(context)
    req = context.request
    resp = context.response
    resp.status_code = 302
    resp.headers["Location"] = "https://#{req.headers["Host"]?.try(&.split(':')[0])}#{req.resource}"
  end

  def self.websocket_upgrade_request?(request)
    return false unless upgrade = request.headers["Upgrade"]?
    return false unless upgrade.compare("websocket", case_insensitive: true) == 0

    request.headers.includes_word?("Connection", "Upgrade")
  end

  # Used in base.cr to build routes for the redirect_to helpers
  def self.build_route(route, hash_parts : Hash((String | Symbol), (Nil | Bool | Int32 | Int64 | Float32 | Float64 | String | Symbol))? = nil, **tuple_parts)
    return route if hash_parts.nil? && tuple_parts.empty? && !route.includes?(':')

    params = {} of String => String?
    hash_parts.try(&.each { |key, value| params[key.to_s] = value.try(&.to_s) })
    # Merge before substitution so explicit arguments also override bound path values.
    tuple_parts.each { |key, value| params[key.to_s] = value.try(&.to_s) }

    missing = [] of String
    segments = [] of String
    optional_missing = nil.as(String?)
    route.split('/').each do |segment|
      if segment.starts_with?(':') || segment.starts_with?("?:") || segment.starts_with?("*:")
        key = segment.byte_slice(segment.starts_with?(':') ? 1 : 2)
        present = params.has_key?(key)
        value = params.delete(key)
        if segment.starts_with?(':')
          missing << key unless present
          segments << URI.encode_path_segment(value.to_s)
        elsif value
          if omitted = optional_missing
            raise ActionController::InvalidRoute.new("optional route parameter :#{key} requires :#{omitted} for #{route}")
          end
          segments << (segment.starts_with?("*:") ? URI.encode_path(value) : URI.encode_path_segment(value))
        else
          optional_missing ||= key
        end
      else
        segments << segment
      end
    end
    raise ActionController::InvalidRoute.new("route parameters missing :#{missing.join(", :")} for #{route}") unless missing.empty?
    route = segments.join('/')
    route = "/" if route.empty?

    # Add any remaining values as query params
    if params.empty?
      route
    else
      "#{route}?#{URI::Params.encode(params.transform_values(&.to_s))}"
    end
  end

  # Extracts the mime type from the content type header
  def self.content_type(headers)
    ctype = headers["Content-Type"]?.presence
    return MIME::MediaType.parse(ctype).media_type if ctype
    nil
  rescue
    nil
  end

  def self.media_type(headers)
    ctype = headers["Content-Type"]?.presence
    return MIME::MediaType.parse(ctype) if ctype
    nil
  rescue
    nil
  end

  def self.charset(headers)
    media_type(headers).try(&.[]?("charset").try(&.downcase)) || "utf-8"
  end
end
