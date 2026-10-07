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
  #
  # Segments follow the router: `:name` is required, and optional `?:name` and glob `*:name`
  # segments come after the required ones (wherever they're written), each added in turn while
  # a value is provided. A glob keeps its slashes. Any other values become query params.
  def self.build_route(route, hash_parts : Hash((String | Symbol), (Nil | Bool | Int32 | Int64 | Float32 | Float64 | String | Symbol))? = nil, **tuple_parts)
    # Tuple overwrites hash parts (so safe to use a user generated hash)
    values = {} of String => String?
    hash_parts.try &.each { |key, value| values[key.to_s] = value.try(&.to_s) }
    tuple_parts.each { |key, value| values[key.to_s] = value.try(&.to_s) }

    parts = route.split('/')
    optional = parts.select { |part| part.starts_with?("?:") || part.starts_with?("*:") }
    optional_names = optional.map(&.[2..])
    missing = [] of String

    segments = parts.reject { |part| part.starts_with?("?:") || part.starts_with?("*:") }.map do |segment|
      next segment unless segment.starts_with?(':')
      name = segment.lchop(':')
      if value = values.delete(name)
        URI.encode_path_segment(value)
      else
        missing << name
        segment
      end
    end

    # Raise error if not all parts are substituted
    raise ActionController::InvalidRoute.new("route parameters missing :#{missing.join(", :")} for #{route}") unless missing.empty?

    unless optional.empty?
      segments.pop if segments.size > 1 && segments.last.empty?
      optional.each do |segment|
        name = segment[2..]
        break unless value = values[name]?.presence
        values.delete(name)
        segments << (segment.starts_with?('*') ? URI.encode_path(value) : URI.encode_path_segment(value))
      end
    end
    path = segments.join('/')

    # Add any remaining values as query params, an optional segment without a value is left out
    params = {} of String => String
    values.each do |key, value|
      next if value.nil? && optional_names.includes?(key)
      params[key] = value || ""
    end

    if params.empty?
      path
    else
      "#{path}?#{URI::Params.encode(params)}"
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
