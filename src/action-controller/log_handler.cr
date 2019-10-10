# A handler that logs the request method, resource, status code, and
# the time used to execute the next handler, to the given `IO`.
class ActionController::LogHandler
  include HTTP::Handler

  # Initializes this handler to log to the given `IO`.
  def initialize(@io : IO, &@tags : Proc(HTTP::Server::Context, String))
    @logger = Channel(String).new(128)
    spawn { write_logs! }
  end

  def call(context)
    elapsed = Time.measure { call_next(context) }
    elapsed_text = elapsed_text(elapsed)
    tags = @tags.call(context)
    @logger.send("method=#{context.request.method} status=#{context.response.status_code} path=#{context.request.resource} duration=#{elapsed_text}#{tags}")
  rescue e
    tags = begin
      @tags.call(context)
    rescue e
      @logger.send "error building custom tag list\n#{e.inspect_with_backtrace}"
      nil
    end
    @logger.send "method=#{context.request.method} status=500 path=#{context.request.resource}#{tags}\n#{e.inspect_with_backtrace}"
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

  private def write_logs!
    loop do
      text = @logger.receive?
      break unless text

      @io.puts text
      @io.flush
    end
  end
end
