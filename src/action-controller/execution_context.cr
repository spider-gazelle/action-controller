module ActionController
  # Manages the optional response execution context.
  #
  # When compiled with `-Dpreview_mt -Dexecution_context` the response body
  # serialisation (typically converting a handler's return value into JSON) runs
  # in a dedicated parallel execution context. Moving the serialisation off the
  # request fiber means a large, CPU heavy JSON response is serialised in
  # parallel and cannot cause head-of-line blocking of other requests.
  #
  # When execution contexts are **not** enabled the configuration is a no-op and
  # `serialize_response` simply yields inline, so third party code referencing
  # this module still compiles unchanged.
  module ExecutionContext
    {% if flag?(:execution_context) %}
      # execution contexts are available, responses are serialised separately

      # guards lazy creation of the context
      @@mutex = ::Mutex.new

      # number of parallel schedulers serialising responses (default 4)
      @@response_parallelism : Int32 = 4

      @@response_context : ::Fiber::ExecutionContext::Parallel? = nil

      # the number of parallel schedulers used to serialise response bodies.
      # must be configured before the server starts as the context is built lazily.
      def self.response_parallelism : Int32
        @@response_parallelism
      end

      # configure the number of parallel schedulers used to serialise responses
      def self.response_parallelism=(size : Int32) : Int32
        @@response_parallelism = size
      end

      # the execution context response bodies are serialised in
      def self.response_context : ::Fiber::ExecutionContext::Parallel
        @@response_context || @@mutex.synchronize do
          @@response_context ||= ::Fiber::ExecutionContext::Parallel.new("ac-response", @@response_parallelism)
        end
      end

      # serialise a response body in the response execution context.
      #
      # The captured block is piped over a channel to a fiber spawned in the
      # response context. The calling (request) fiber blocks until the block
      # completes, freeing it to handle other requests while the potentially CPU
      # heavy serialisation runs in parallel. Any error is propagated back to the
      # request fiber.
      def self.serialize_response(&block : ->) : Nil
        done = ::Channel(::Exception?).new
        response_context.spawn do
          block.call
          done.send nil
        rescue error
          done.send error
        end
        if error = done.receive
          raise error
        end
      end
    {% else %}
      # execution contexts are unavailable, the configuration is a no-op

      # :nodoc:
      def self.response_parallelism : Int32
        4
      end

      # no-op: execution contexts are not enabled
      def self.response_parallelism=(size : Int32) : Int32
        size
      end

      # runs the serialisation inline, there is no separate response context
      def self.serialize_response(&) : Nil
        yield
      end
    {% end %}
  end
end
