require "json"
require "random"
require "./session/message_verifier"
require "./session/message_encryptor"

class ActionController::Session < Hash(String, String | Int64 | Float64 | Bool)
  NEVER = 622_080_000 # (~20 years in seconds)
  # Cookies can typically store 4096 bytes.
  MAX_COOKIE_SIZE = 4096

  Habitat.create do
    setting key : String
    setting secret : String
    setting max_age : Int32 = NEVER
    setting secure : Bool = false
    setting encrypted : Bool = true
    setting path : String = "/"
  end

  # Returns whether any key-value pair is modified.
  getter modified : Bool
  @encoder : MessageEncryptor | MessageVerifier

  def initialize
    super

    @modified = false
    @existing = false

    if settings.encrypted
      @encoder = MessageEncryptor.new(settings.secret)
    else
      @encoder = MessageVerifier.new(settings.secret)
    end
  end

  def self.from_cookies(cookies)
    session = ActionController::Session.new
    session.parse(cookies)
    session
  end

  def parse(cookies)
    cookie = cookies[settings.key]?

    if cookie
      data = @encoder.extract(cookie.value).to_s
      self.merge!(Hash(String, String | Int64 | Float64 | Bool).from_json(data))
      @modified = false
      @existing = true
    end
  end

  def encode(cookies)
    # If there was no existing session and
    return if !@existing && self.empty?

    # TODO:: Add secure setting

    if @existing && self.empty?
      data = ""
      age = 0
    else
      data = @encoder.prepare(self.to_json)
      age = settings.max_age
      raise CookieSizeExceeded.new("#{data.size} > #{MAX_COOKIE_SIZE}") if data.size > MAX_COOKIE_SIZE
    end
    cookies[settings.key] = HTTP::Cookie.new(
      settings.key,
      data,
      settings.path,
      Time.now + age.seconds,
      http_only: true,
      extension: "SameSite=Strict"
    )
  end

  def []=(key, value)
    if value.nil?
      delete(key)
    else
      super(key, value)
      @modified = true
    end
    value
  end

  def clear
    @modified = true if @existing
    super
  end

  def delete(key)
    @modified = true
    super(key)
  end

  def delete(key, &block)
    @modified = true
    super(key, &block)
  end

  def delete_if(&block)
    @modified = true
    super(&block)
  end

  def touch
    @modified = true
  end
end
