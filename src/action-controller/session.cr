require "json"
require "random"
require "./session/message_verifier"
require "./session/message_encryptor"

class ActionController::Session
  Log = ::Log.for("action-controller.session")

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
    setting domain : String? = nil
  end

  # Returns whether any key-value pair is modified.
  getter modified : Bool
  property domain : String?
  @encoder : MessageEncryptor | MessageVerifier
  @store : Hash(String, String | Int64 | Float64 | Bool)

  forward_missing_to @store

  def initialize
    @modified = false
    @existing = false
    @domain = settings.domain

    if settings.encrypted
      @encoder = MessageEncryptor.new(settings.secret)
    else
      @encoder = MessageVerifier.new(settings.secret)
    end

    @store = {} of String => String | Int64 | Float64 | Bool
  end

  def self.from_cookies(cookies)
    session = ActionController::Session.new
    begin
      session.parse(cookies)
    rescue error
      Log.warn(exception: error) { "error parsing session" }
    end
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

    if @existing && self.empty?
      data = ""
      age = 0
    else
      data = @encoder.prepare(self.to_json)
      age = settings.max_age
      raise CookieSizeExceeded.new("#{data.size} > #{MAX_COOKIE_SIZE}") if data.size > MAX_COOKIE_SIZE
    end

    @modified = false

    cookies[settings.key] = HTTP::Cookie.new(
      settings.key,
      data,
      settings.path,
      Time.utc + age.seconds,
      @domain,
      settings.secure,
      http_only: true,
      extension: "SameSite=Lax"
    )
  end

  def []=(key, value)
    if value.nil?
      delete(key)
    else
      @store[key] = value
      @modified = true
    end
    value
  end

  def clear
    @modified = true if @existing
    @store.clear
  end

  def delete(key)
    @modified = true
    @store.delete(key)
  end

  def delete(key, &block)
    @modified = true
    @store.delete(key, &block)
  end

  def delete_if(&block)
    @modified = true
    @store.delete_if(&block)
  end

  def touch
    @modified = true
  end
end
