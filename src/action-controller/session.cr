require "json"
require "random"
require "./session/message_verifier"
require "./session/message_encryptor"

class ActionController::Session < Hash(String, String | Int64 | Float64 | Bool)
  # Cookies can typically store 4096 bytes.
  NEVER           = 622080000 # (~20 years in seconds)
  MAX_COOKIE_SIZE =      4096

  Habitat.create do
    setting key : String
    setting secret : String
    setting max_age : Int32 = NEVER
    setting secure : Bool = false
    setting encrypted : Bool = true
    setting path : String = "/"
  end

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
      data = "; Path=#{settings.path}; Max-Age=0; HttpOnly; SameSite=Strict"
    else
      data = @encoder.prepare(self.to_json)
      raise CookieSizeExceeded.new("#{data.size} > #{MAX_COOKIE_SIZE}") if data.size > MAX_COOKIE_SIZE
      data = "#{data}; Path=#{settings.path}; Max-Age=#{settings.max_age}; HttpOnly; SameSite=Strict"
    end
    cookies[settings.key] = data
  end

  def []=(key, value)
    super(key, value)
    @modified = true
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
