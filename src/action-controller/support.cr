module ActionController::Support
  def self.request_protocol(request)
    return :https if request.headers["X-Forwarded-Proto"]? =~ /https/i
    return :https if request.headers["Forwarded"]? =~ /https/i
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
    keys = route.split("/:")[1..-1].map &.split("/")[0]
    params = {} of String => String

    if hash_parts
      hash_parts.each do |key, value|
        key = key.to_s
        value = value.to_s

        if keys.includes?(key)
          route = route.sub(":#{key}", URI.encode_path(value))
          keys.delete(key)
        else
          params[key] = value
        end
      end
    end

    # Tuple overwrites hash parts (so safe to use a user generated hash)
    tuple_parts.each do |key, value|
      key = key.to_s
      value = value.to_s

      if keys.includes?(key)
        route = route.sub(":#{key}", URI.encode_path(value))
        keys.delete(key)
      else
        params[key] = value
      end
    end

    # Raise error if not all parts are substituted
    raise ActionController::InvalidRoute.new("route parameters missing :#{keys.join(", :")} for #{route}") unless keys.empty?

    # Add any remaining values as query params
    if params.empty?
      route
    else
      "#{route}?#{URI::Params.encode(params)}"
    end
  end

  TYPE_SEPARATOR_REGEX = /;\s*/

  # Extracts the mime type from the content type header
  def self.content_type(headers)
    ctype = headers["Content-Type"]?
    if ctype && !ctype.empty?
      ctype = ctype.split(TYPE_SEPARATOR_REGEX).first?
      return ctype if ctype && !ctype.empty?
    end
    nil
  end
end
