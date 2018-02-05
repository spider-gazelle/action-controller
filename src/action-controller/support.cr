class ActionController::Support
  def self.request_protocol(request)
    return :https if request.headers["X-Forwarded-Proto"]? =~ /https/i
    return :https if request.headers["Forwarded"]? =~ /https/i
    :http
  end

  def self.redirect_to_https(context)
    req = context.request
    resp = context.response
    resp.status_code = 302
    resp.headers["Location"] = "https://#{req.host}#{req.resource}"
  end

  def self.websocket_upgrade_request?(request)
    return false unless upgrade = request.headers["Upgrade"]?
    return false unless upgrade.compare("websocket", case_insensitive: true) == 0

    request.headers.includes_word?("Connection", "Upgrade")
  end
end
