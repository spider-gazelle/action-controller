require "./spec_helper"

describe ActionController::Logger do
  ActionController::Logger.add_tag response_id
  ActionController::Logger.add_tag user_id

  io = IO::Memory.new
  root_logger = ActionController::Logger.new(io)
  tagged_logger = ActionController::Logger::TaggedLogger.new(root_logger)

  Spec.before_each { io.clear }

  it "tags an event and ignores unused tags" do
    tagged_logger.response_id = "12345"
    tagged_logger.info "what's happening?"
    io.to_s.ends_with?("response_id=12345 message=what's happening?\n").should eq(true)
  end

  it "tags in definition order" do
    tagged_logger.user_id = "user-abc"
    tagged_logger.response_id = "12345"
    tagged_logger.info "what's happening?"
    io.to_s.ends_with?("response_id=12345 user_id=user-abc message=what's happening?\n").should eq(true)
  end

  it "tags supports custom tags" do
    tagged_logger.user_id = "user-abc"
    tagged_logger.tag "interesting details", me: "Steve", other: 567
    io.to_s.ends_with?("response_id=12345 user_id=user-abc me=Steve other=567 message=interesting details\n").should eq(true)
  end

  {% for name in Logger::Severity.constants %}
    {% method = name.downcase %}
    it "#tag_#{{{ method.stringify }}} curries #{{{ method.stringify }}} severity" do
      tagged_logger.level =  Logger::Severity::{{name}}
      tagged_logger.tag_{{method.id}}(message: "wow, code", broken: false)
      logged = io.to_s
      if {{ name.stringify }} == "UNKNOWN"
        logged.should start_with %(level=ANY)
      else
        logged.should start_with %(level=#{{{ name.stringify }}})
      end
      logged.should end_with %(broken=false message=wow, code\n)
    end
  {% end %}
end
