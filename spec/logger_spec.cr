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
end
