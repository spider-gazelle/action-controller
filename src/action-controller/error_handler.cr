require "exception_page"

module ActionController::ErrorHandler
  def self.new(production : Bool = false, persist_headers = [] of String)
    if production
      ActionController::ErrorHandlerProduction.new(persist_headers)
    else
      ActionController::ErrorHandlerDevelopment.new(persist_headers)
    end
  end
end

class ActionController::ExceptionPage < ExceptionPage
  def styles : Styles
    ExceptionPage::Styles.new(
      # Choose the HTML color value. Can be hex
      accent: "purple",
    )
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
      return accepts if accepts && !accepts.empty?
    end
    [] of String
  end
end

class ActionController::ErrorHandlerDevelopment
  include ActionController::ErrorHandlerBase
  include HTTP::Handler

  def call(context)
    call_next(context)
  rescue ex : Exception
    response = context.response
    reset(response)

    ActionController::ExceptionPage.for_runtime_exception(context, ex).to_s(context.response)
  end
end

class ActionController::ErrorHandlerProduction
  include ActionController::ErrorHandlerBase
  include HTTP::Handler

  def call(context)
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
