class ActionController::Error < Exception
end

class ActionController::CookieSizeExceeded < ActionController::Error
end

class ActionController::InvalidSignature < ActionController::Error
end
