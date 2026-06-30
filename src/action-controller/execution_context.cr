module ActionController
  # Manages the optional response execution context(s).
  #
  # When compiled with `-Dpreview_mt -Dexecution_context` the response body
  # serialisation (typically converting a handler's return value into JSON) runs
  # in a dedicated parallel execution context. Moving the serialisation off the
  # request fiber means a large, CPU heavy JSON response is serialised in
  # parallel and cannot cause head-of-line blocking of other requests.
  #
  # Applications `define` named contexts and bind them to a controller
  # (`execution_context "name"`) or an individual route
  # (`@[AC::Route::GET("/", execution_context: "name")]`) so heavy endpoints get
  # their own dedicated pool - the whole request runs there. The binding is
  # resolved at compile time - the generated route code calls the chosen context's
  # getter directly, there is no per-request lookup. Named contexts are created
  # once, lazily, on first use.
  #
  # Routes that are **not** bound to a context serialise their response inline on
  # the request fiber by default. Call `offload_responses` to instead offload
  # those responses to the shared `response_context` (useful when unbound routes
  # can return large payloads).
  #
  # ```
  # # configure your contexts (e.g. in config.cr), names are string literals
  # ActionController::ExecutionContext.define "reports", parallelism: 2
  # ActionController::ExecutionContext.define "heavy-json" # default size
  # ```
  #
  # When execution contexts are **not** enabled the configuration is a no-op and
  # `serialize_response` simply yields inline, so third party code referencing
  # this module still compiles unchanged.
  module ExecutionContext
    # :nodoc:
    # compile-time registry of named contexts: name => default parallelism.
    # declared regardless of the compilation flags so the route builder can
    # validate names in both modes.
    CONTEXTS = {} of Nil => Nil

    # :nodoc:
    # compile-time guard against two names sanitising to the same getter:
    # sanitised method suffix => original name
    CONTEXT_METHODS = {} of Nil => Nil

    # :nodoc:
    # compile-time toggle: should responses from routes WITHOUT a dedicated
    # execution context be offloaded to the shared response context? Off by
    # default - opt in with `offload_responses`. Resolved entirely at macro time
    # so there is no runtime check.
    OFFLOAD_RESPONSES = [false]

    # enable offloading of responses to the shared `response_context` for routes
    # and controllers that are **not** bound to a dedicated execution context.
    #
    # Off by default: by default an unbound response is serialised inline on the
    # request fiber (no spawn, no channel) which is cheaper for small responses.
    # Enable it when your unbound routes can return large, CPU heavy payloads that
    # would otherwise cause head-of-line blocking.
    #
    # This is a compile-time switch - call it before your controllers are
    # finalised (e.g. in config.cr). It has no effect without the execution
    # context compilation flags.
    #
    # ```
    # ActionController::ExecutionContext.offload_responses
    # ```
    macro offload_responses(enabled = true)
      {% ::ActionController::ExecutionContext::OFFLOAD_RESPONSES[0] = enabled %}
    end

    # define a named execution context, created once and lazily on first use.
    #
    # ```
    # ActionController::ExecutionContext.define "reports", parallelism: 2
    # ```
    #
    # The size can be overridden at runtime before the context is first used via
    # `ActionController::ExecutionContext.parallelism("reports", n)`. Without the
    # execution context compilation flags this only records the name (so routes
    # referencing it still validate) and creates no context.
    macro define(name, parallelism = 4)
      {% san = name.gsub(/\W/, "_") %}
      {% existing = ::ActionController::ExecutionContext::CONTEXT_METHODS[san] %}
      {% if existing != nil %}
        {% raise "execution context #{name} clashes with already defined context #{existing} (both map to `context_#{san.id}`)" %}
      {% end %}
      {% ::ActionController::ExecutionContext::CONTEXT_METHODS[san] = name %}
      {% ::ActionController::ExecutionContext::CONTEXTS[name] = parallelism %}

      {% if flag?(:execution_context) %}
        module ActionController::ExecutionContext
          @@context_{{san.id}} : ::Fiber::ExecutionContext::Parallel? = nil

          # the lazily created "{{name.id}}" execution context
          def self.context_{{san.id}} : ::Fiber::ExecutionContext::Parallel
            @@context_{{san.id}} || @@mutex.synchronize do
              @@context_{{san.id}} ||= ::Fiber::ExecutionContext::Parallel.new({{name}}, @@parallelism_overrides[{{name}}]? || {{parallelism}})
            end
          end
        end
      {% end %}
    end

    # run a block in an execution context (defaulting to the shared
    # `response_context`), blocking the calling fiber until it completes.
    #
    # Used both to offload just the response serialisation (default context) and
    # to run a whole request in a controller/route bound context. The block is
    # **inlined** into the fiber spawned in the chosen context - the calling fiber
    # blocks on a channel until it completes, freeing it to handle other requests
    # while the potentially CPU heavy work runs in parallel. Any error is
    # propagated back to the calling fiber. Implemented as a macro so the body is
    # not captured as a separate closure.
    #
    # Without the execution context compilation flags the block simply runs inline.
    macro offload(context = nil, &block)
      {% if flag?(:execution_context) %}
        # buffered (capacity 1) so the worker can hand back the result and return
        # its stack to the pool without waiting for a rendezvous.
        %done = ::Channel(::Exception?).new(1)
        {% if context %}{{context}}{% else %}::ActionController::ExecutionContext.response_context{% end %}.spawn do
          {{block.body}}
          %done.send nil
        rescue %error
          %done.send %error
        end
        if %error = %done.receive
          raise %error
        end
      {% else %}
        {{block.body}}
      {% end %}
    end

    {% if flag?(:execution_context) %}
      # execution contexts are available, responses are serialised separately

      # guards lazy creation of the contexts
      @@mutex = ::Mutex.new

      # number of parallel schedulers serialising responses (default 4)
      @@response_parallelism : Int32 = 4

      @@response_context : ::Fiber::ExecutionContext::Parallel? = nil

      # runtime parallelism overrides for named contexts: name => size.
      # consulted once when the named context is lazily created.
      @@parallelism_overrides = {} of String => Int32

      # the number of parallel schedulers used to serialise response bodies.
      # must be configured before the server starts as the context is built lazily.
      def self.response_parallelism : Int32
        @@response_parallelism
      end

      # configure the number of parallel schedulers used to serialise responses
      def self.response_parallelism=(size : Int32) : Int32
        @@response_parallelism = size
      end

      # override the parallelism of a named context before it is first used (e.g.
      # to size it from an environment variable). Has no effect once the context
      # has been created.
      def self.parallelism(name : String, size : Int32) : Int32
        @@parallelism_overrides[name] = size
      end

      # the default execution context response bodies are serialised in
      def self.response_context : ::Fiber::ExecutionContext::Parallel
        @@response_context || @@mutex.synchronize do
          @@response_context ||= ::Fiber::ExecutionContext::Parallel.new("ac-response", @@response_parallelism)
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

      # no-op: execution contexts are not enabled
      def self.parallelism(name : String, size : Int32) : Int32
        size
      end
    {% end %}
  end
end
