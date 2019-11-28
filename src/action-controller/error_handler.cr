module ActionController::ErrorHandler
  def self.new(development : Bool = false, persist_headers = [] of String)
    if development
      ActionController::ErrorHandlerDevelopment.new(persist_headers)
    else
      ActionController::ErrorHandlerProduction.new(persist_headers)
    end
  end
end

module ActionController::ErrorHandlerBase
  def initialize(@headers : Array(String))
  end

  def reset(response)
    save_headers = {} of String => String
    @headers.each do |key|
      if header = response.headers[key]?
        save_headers[key] = header
      end
    end
    response.reset
    save_headers.each { |key, value| response.headers[key] = value }
    response.status = :internal_server_error
  end

  ACCEPT_SEPARATOR_REGEX = /,\s*/

  def accepts_formats(request)
    accept = request.headers["Accept"]?
    if accept && !accept.empty?
      accepts = accept.split(";").first?.try(&.split(ACCEPT_SEPARATOR_REGEX))
      return accepts if accepts && accepts.any?
    end
    [] of String
  end
end

class ActionController::ErrorHandlerDevelopment
  include ActionController::ErrorHandlerBase
  include HTTP::Handler

  def call(context)
    begin
      call_next(context)
    rescue ex : Exception
      response = context.response
      reset(response)

      if accepts_formats(context.request).includes?("application/json")
        response.content_type = "application/json"
        {
          error:     ex.message,
          backtrace: ex.backtrace?,
        }.to_json(response)
      else
        response.content_type = "text/plain"
        response.print("ERROR: ")
        ex.inspect_with_backtrace(response)
      end
    end
  end
end

class ActionController::ErrorHandlerProduction
  include ActionController::ErrorHandlerBase
  include HTTP::Handler

  def call(context)
    begin
      call_next(context)
    rescue ex : Exception
      response = context.response
      reset(response)

      if accepts_formats(context.request).includes?("application/json")
        response.content_type = "application/json"
        response.print("{}")
      else
        context.response.content_type = "text/plain"
      end
    end
  end
end
