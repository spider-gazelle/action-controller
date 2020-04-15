require "./spec_helper"

module ActionController
  describe ::Log do
    backend = ::Log::MemoryBackend.new
    ::Log.setup_from_env(sources: "*", level: "info", backend: backend)

    Spec.before_each { Log.context.clear }

    it "tags an event and ignores unused tags" do
      ::Log.context.set response_id: "12345"
      ::Log.info { "what's happening?" }
      message = backend.entries.first.message
      message.should end_with("response_id=12345 message=what's happening?\n")
    end

    it "tags in definition order" do
      ::Log.context.set user_id: "user-abc", response_id: "12345"
      ::Log.info { "what's happening?" }
      message = backend.entries.first.message
      message.should end_with("response_id=12345 user_id=user-abc message=what's happening?\n")
    end

    it "set custom tags" do
      ::Log.context.set user_id: "user-abc"

      # Temporary context
      ::Log.with_context do
        ::Log.context.set me: "Steve", other: 567
        ::Log.info { "interesting details" }
      end

      message = backend.entries.first.message
      message.should end_with("response_id=12345 user_id=user-abc me=Steve other=567 message=interesting details\n")
    end

    it "supports custom tag types" do
      ::Log.context.set({upstream_latency: 10_000.nanoseconds.to_i})
      ::Log.info { "what's happening?" }
      message = backend.entries.first.message
      message.should end_with("upstream_latency=00:00:00.000010000 message=what's happening?\n")
    end
  end
end
