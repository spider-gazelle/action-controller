require "http/request"

module ActionController::MCPServer
  # the MCP request a route is running for, available to the route as `mcp_context`.
  #
  # Routes annotated `@[AC::MCP(long_running: true)]` are streamed to clients that
  # accept an event stream: they can report progress, and are cancelled when the client
  # disconnects
  #
  # ```
  # @[AC::MCP(long_running: true)]
  # @[AC::Route::GET("/:id/export")]
  # def export(id : Int64) : Nil
  #   rows = Row.where(widget_id: id)
  #   rows.each_with_index do |row, index|
  #     break if mcp_context.try &.cancelled?
  #     response << row.to_csv
  #     mcp_context.try &.progress(index + 1, rows.size)
  #   end
  # end
  # ```
  class RequestContext
    # the `_meta.progressToken` of the request, progress isn't reported without one
    getter progress_token : JSON::Any?

    # closed when the request is cancelled, select on it to stop waiting
    getter done : Channel(Nil) = Channel(Nil).new

    # true once the response has reached the route's `max_bytes`
    property? full : Bool = false

    # sends a notification on the response stream, set by the transport
    protected property notifier : Proc(String, Nil)? = nil

    @cancelled = Atomic(Bool).new(false)
    @last_progress : Float64? = nil
    @lock = Mutex.new

    def initialize(@progress_token = nil)
    end

    # the client disconnected, the route should stop work
    def cancelled? : Bool
      @cancelled.get
    end

    # :nodoc:
    def cancel : Nil
      done.close unless @cancelled.swap(true)
    end

    # reports progress to the client, ignored when the client didn't request progress.
    # Progress must increase, values that don't are ignored
    def progress(progress : Number, total : Number? = nil, message : String? = nil) : Nil
      return unless (token = progress_token) && (notify = notifier)
      return if cancelled?
      value = progress.to_f64
      @lock.synchronize do
        return if (last = @last_progress) && value <= last
        @last_progress = value
      end

      notify.call(JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "method", "notifications/progress"
          json.field "params" do
            json.object do
              json.field "progressToken", token
              json.field "progress", progress
              json.field "total", total if total
              json.field "message", message if message
            end
          end
        end
      end)
    end
  end
end

class HTTP::Request
  # the MCP request the request is running for, when invoked by the MCP server
  property mcp_context : ActionController::MCPServer::RequestContext? = nil
end

abstract class ActionController::Base
  # the MCP request this route is running for, `nil` for regular HTTP requests.
  # See `ActionController::MCPServer::RequestContext`
  def mcp_context : ActionController::MCPServer::RequestContext?
    request.mcp_context
  end
end
