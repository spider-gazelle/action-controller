require "./logger"

# A handler that logs the request method, resource, status code, and
# the time used to execute the next handler, to the given `IO`.
module ActionController
  class LogHandler
    include HTTP::Handler

    # Initializes this handler to log to the given `IO`.
    def initialize(filter = nil)
      @filter = filter ? filter.to_a.map(&.to_s) : [] of String
    end

    @filter : Array(String)

    def call(context)
      ::Log.context.clear

      elapsed = Time.measure { call_next(context) }

      Log.info &.emit(
        duration: elapsed_text(elapsed),
        method: context.request.method,
        path: filter_path(context.request.resource),
        status: context.response.status_code
      )
    rescue e
      Log.error(exception: e, &.emit(
        method: context.request.method,
        path: filter_path(context.request.resource),
        status: 500,
        duration: elapsed_text(elapsed ? elapsed : 0.seconds),
      ))

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

    private def filter_path(path)
      return path if @filter.empty?
      path.gsub(/(\?|\&)([^&;=]+)=([^&;=]+)/) do |value|
        filter = false
        @filter.each do |key|
          if $2 == key
            filter = true
            break
          end
        end
        filter ? "#{$1}#{$2}=[FILTERED]" : value
      end
    end
  end
end
