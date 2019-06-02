# A handler that logs the request method, resource, status code, and
# the time used to execute the next handler, to the given `IO`.
class ActionController::LogHandler
  include HTTP::Handler

  # Initializes this handler to log to the given `IO`.
  def initialize(@io : IO, &@tags : Proc(HTTP::Server::Context, String))
  end

  def call(context)
    elapsed = Time.measure { call_next(context) }
    elapsed_text = elapsed_text(elapsed)
    tags = @tags.call(context)
    @io.puts "method=#{context.request.method} status=#{context.response.status_code} path=#{context.request.resource} duration=#{elapsed_text}#{tags}"
  rescue e
    @io.puts "method=#{context.request.method} status=500 path=#{context.request.resource}#{tags}"
    e.inspect_with_backtrace(@io)
    raise e
  end

  private def elapsed_text(elapsed)
    minutes = elapsed.total_minutes
    return "#{minutes.round(2)}m" if minutes >= 1

    seconds = elapsed.total_seconds
    return "#{seconds.round(2)}s" if seconds >= 1

    millis = elapsed.total_milliseconds
    return "#{millis.round(2)}ms" if millis >= 1

    "#{(millis * 1000).round(2)}µs"
  end
end
