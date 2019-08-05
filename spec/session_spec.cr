require "./spec_helper"

describe ActionController::Session do
  described_class = ActionController::Session
  key = described_class.settings.key
  encoder = ActionController::MessageEncryptor.new(described_class.settings.secret)
  age = ActionController::Session::NEVER.seconds

  describe "#encode" do
    # Encrypted message of 3014 characters occupies 4106 result characters, of 3013 - 3023
    context "with empty and existing session" do
      it "sets expiration to now" do
        cookies = HTTP::Cookies.new
        cookies[key] = HTTP::Cookie.new(key, encoder.prepare(%({"key": "value"})))
        session = described_class.from_cookies(cookies)
        session.delete("key")
        cookies = HTTP::Cookies.new
        session.encode(cookies)

        cookies[key].value.should be_empty
        cookies[key].expires.as(Time).should be_close(Time.utc, 0.1.seconds)
      end
    end

    context "with existing and not empty session" do
      it "creates cookie with data" do
        cookies = HTTP::Cookies.new
        cookies[key] = HTTP::Cookie.new(key, encoder.prepare(%({"key": "value"})))
        session = described_class.from_cookies(cookies)
        session["key"] = "a" * 3013
        cookies = HTTP::Cookies.new
        session.encode(cookies)

        cookies[key].expires.as(Time).should be_close(Time.utc + age, 0.1.seconds)
        encoder.extract(cookies[key].value).should eq(%({"key":"#{"a" * 3013}"}))
      end
    end

    context "with not existing and empty session" do
      it "doesn't create cookie" do
        session = described_class.new
        cookies = HTTP::Cookies.new
        session.encode(cookies)

        cookies.has_key?(key).should be_false
      end
    end

    context "with too large data" do
      it "raises CookieSizeExceeded exception" do
        cookies = HTTP::Cookies.new
        cookies[key] = HTTP::Cookie.new(key, encoder.prepare(%({"key": "value"})))
        session = described_class.from_cookies(cookies)
        session["key"] = "a" * 3014
        cookies = HTTP::Cookies.new

        expect_raises(ActionController::CookieSizeExceeded) do
          session.encode(cookies)
        end
      end
    end
  end
end
